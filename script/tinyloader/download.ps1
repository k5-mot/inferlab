[CmdletBinding()]
param(
    # regctl image export で取得するイメージ参照。
    [Parameter(Mandatory = $true)]
    [string]$ImageRef,

    # 1 Part の最大サイズ。Windows 側の quota より十分小さい値にする。
    [Parameter(Mandatory = $true)]
    [ValidateScript({ $_ -gt 0 })]
    [double]$PartSizeGB,

    # Docker daemon を使わず registry から export するための regctl 実行ファイル。
    [string]$RegctlPath = ".\regctl.exe",

    [ValidateRange(1, 1048576)]
    [int]$ProgressIntervalMB = 256,

    [switch]$SkipOciValidation,

    [ValidateRange(1, 1024)]
    [int]$OciMetadataMaxMB = 16,

    [switch]$ResetState
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# 巨大 blob の転送では registry 側の一時切断が起きることがあるため、
# regctl の export は数回だけ再試行する。途中までできた Part は再試行前に削除する。
$script:RegctlMaxAttempts = 3
$script:RegctlRetryDelaySeconds = 15

# このスクリプトは巨大な docker load 互換 tar をローカルに丸ごと保存しない。
# 1 回の実行で Part を 1 個だけ作り、ユーザが手動でファイルサーバへ移動した後、
# 次回実行時に state を進めて次の Part を作る。
$ScriptDirectory = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    $PSScriptRoot
}

if ([string]::IsNullOrWhiteSpace($ScriptDirectory)) {
    $ScriptDirectory = (Get-Location).ProviderPath
}

# regctl.exe の実体を解決する。相対パス指定と PATH 上のコマンド名指定の両方を許可する。
function Resolve-ExecutablePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Path).ProviderPath
    }

    $command = Get-Command -Name $Path -ErrorAction SilentlyContinue
    if ($null -ne $command -and $null -ne $command.Source) {
        return $command.Source
    }

    throw "regctl was not found: $Path"
}

# ImageRef から Part ファイル名のベースを作る。
# docker.io/vllm/vllm-openai:v0.19.1 -> vllm_vllm-openai_v0.19.1
function Get-ImageFileBase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reference
    )

    $name = $Reference
    $slashIndex = $name.IndexOf("/")

    if ($slashIndex -ge 0) {
        $first = $name.Substring(0, $slashIndex)
        if ($first -match "[\.:]" -or $first -eq "localhost") {
            $name = $name.Substring($slashIndex + 1)
        }
    }

    $base = $name -replace "[\\/:\*\?`"<>|]+", "_"
    $base = $base.Trim(" ", ".")

    if ([string]::IsNullOrWhiteSpace($base)) {
        throw "Could not derive a safe file name from ImageRef: $Reference"
    }

    return $base
}

# .NET ProcessStartInfo.Arguments 用の最小限のクォート処理。
# PowerShell の呼び出し演算子ではなく .NET Process で regctl を起動するために使う。
function ConvertTo-ProcessArgument {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.Length -eq 0) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashCount = 0

    foreach ($char in $Value.ToCharArray()) {
        if ($char -eq "\") {
            $backslashCount++
            continue
        }

        if ($char -eq '"') {
            [void]$builder.Append("\" * ($backslashCount * 2 + 1))
            [void]$builder.Append('"')
            $backslashCount = 0
            continue
        }

        if ($backslashCount -gt 0) {
            [void]$builder.Append("\" * $backslashCount)
            $backslashCount = 0
        }

        [void]$builder.Append($char)
    }

    if ($backslashCount -gt 0) {
        [void]$builder.Append("\" * ($backslashCount * 2))
    }

    [void]$builder.Append('"')
    return $builder.ToString()
}

function Set-RegctlProcessEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.ProcessStartInfo]$StartInfo
    )

    # Docker Hub の大きな blob で HTTP2 の GOAWAY/stream error が発生することがある。
    # ユーザが明示的に GODEBUG=http2client=... を指定していない場合だけ、regctl 子プロセスで HTTP/1.1 を使わせる。
    $goDebug = $StartInfo.EnvironmentVariables["GODEBUG"]
    if ([string]::IsNullOrWhiteSpace($goDebug)) {
        $StartInfo.EnvironmentVariables["GODEBUG"] = "http2client=0"
        return
    }

    if ($goDebug -notmatch "(^|,)http2client=") {
        $StartInfo.EnvironmentVariables["GODEBUG"] = $goDebug + ",http2client=0"
    }
}

# regctl image export を stdout パイプ付きで起動する Process を作る。
# regctl v0.11.3 では "image export IMAGE -" が "-" というファイルを作るため、
# stdout 既定動作の "image export IMAGE" を使う。
function New-RegctlExportProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedRegctlPath,

        [Parameter(Mandatory = $true)]
        [string]$Reference
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $ResolvedRegctlPath
    $startInfo.Arguments = "image export " + (ConvertTo-ProcessArgument $Reference)
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $false
    $startInfo.CreateNoWindow = $true
    Set-RegctlProcessEnvironment -StartInfo $startInfo

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    return $process
}

function Test-RegctlTransientError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    return ($Message -match "regctl exited|Unexpected end|stream error|GOAWAY|INTERNAL_ERROR|connection|timeout|EOF|ended before")
}

function Invoke-WithRegctlRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OperationName,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    for ($attempt = 1; $attempt -le $script:RegctlMaxAttempts; $attempt++) {
        try {
            & $ScriptBlock
            return
        }
        catch {
            $message = $_.Exception.Message
            $canRetry = ($attempt -lt $script:RegctlMaxAttempts -and (Test-RegctlTransientError -Message $message))
            if (-not $canRetry) {
                throw
            }

            Write-Warning ("{0} failed on attempt {1}/{2}: {3}" -f $OperationName, $attempt, $script:RegctlMaxAttempts, $message)
            if ($script:RegctlRetryDelaySeconds -gt 0) {
                Start-Sleep -Seconds $script:RegctlRetryDelaySeconds
            }
        }
    }
}

# 指定バイト数を必ず読み捨てる。tar の payload / padding を安全に進めるための共通処理。
function Read-StreamDiscard {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Stream]$Stream,

        [Parameter(Mandatory = $true)]
        [Int64]$Count,

        [Parameter(Mandatory = $true)]
        [byte[]]$Buffer
    )

    $remaining = $Count
    while ($remaining -gt 0) {
        $readLength = if ($remaining -lt [Int64]$Buffer.Length) { $remaining } else { [Int64]$Buffer.Length }
        $bytesRead = $Stream.Read($Buffer, 0, [int]$readLength)
        if ($bytesRead -le 0) {
            throw "Unexpected end of tar stream."
        }

        $remaining -= $bytesRead
    }
}

# tar ヘッダの ASCII フィールドを取り出す。NUL 終端の固定長領域を想定する。
function Get-TarAsciiField {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$Offset,

        [Parameter(Mandatory = $true)]
        [int]$Length
    )

    $end = $Offset
    $limit = $Offset + $Length
    while ($end -lt $limit -and $Bytes[$end] -ne 0) {
        $end++
    }

    if ($end -le $Offset) {
        return ""
    }

    return [System.Text.Encoding]::ASCII.GetString($Bytes, $Offset, $end - $Offset)
}

# tar の octal フィールドを Int64 に変換する。
function ConvertFrom-TarOctalField {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$Offset,

        [Parameter(Mandatory = $true)]
        [int]$Length,

        [Parameter(Mandatory = $true)]
        [string]$FieldName
    )

    $raw = Get-TarAsciiField -Bytes $Bytes -Offset $Offset -Length $Length
    $value = $raw.Trim([char]0, " ")
    if ([string]::IsNullOrWhiteSpace($value)) {
        return [Int64]0
    }

    if ($value -notmatch "^[0-7]+$") {
        throw "Invalid tar $FieldName field: '$raw'."
    }

    return [Convert]::ToInt64($value, 8)
}

# tar の size フィールドを読む。大きな Layer で使われる base-256 表現にも対応する。
function ConvertFrom-TarSizeField {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $offset = 124
    $length = 12

    if (($Bytes[$offset] -band 0x80) -eq 0) {
        return ConvertFrom-TarOctalField -Bytes $Bytes -Offset $offset -Length $length -FieldName "size"
    }

    [decimal]$value = ($Bytes[$offset] -band 0x7F)
    for ($i = $offset + 1; $i -lt ($offset + $length); $i++) {
        $value = ($value * 256) + $Bytes[$i]
    }

    if ($value -gt [Int64]::MaxValue) {
        throw "Tar entry is too large to handle on this script."
    }

    return [Int64]$value
}

function Test-TarZeroBlock {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    foreach ($byte in $Bytes) {
        if ($byte -ne 0) {
            return $false
        }
    }

    return $true
}

# 1 エントリ分の tar ヘッダを読む。checksum もここで検証する。
function Read-TarHeader {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Stream]$Stream,

        [Parameter(Mandatory = $true)]
        [byte[]]$HeaderBuffer
    )

    $offset = 0
    while ($offset -lt 512) {
        $bytesRead = $Stream.Read($HeaderBuffer, $offset, 512 - $offset)
        if ($bytesRead -le 0) {
            if ($offset -eq 0) {
                return $null
            }

            throw "Unexpected end of tar stream while reading header."
        }

        $offset += $bytesRead
    }

    if (Test-TarZeroBlock -Bytes $HeaderBuffer) {
        return [pscustomobject]@{ IsEnd = $true }
    }

    $expectedChecksum = ConvertFrom-TarOctalField -Bytes $HeaderBuffer -Offset 148 -Length 8 -FieldName "checksum"
    [Int64]$actualChecksum = 0
    for ($i = 0; $i -lt 512; $i++) {
        if ($i -ge 148 -and $i -lt 156) {
            $actualChecksum += 32
        }
        else {
            $actualChecksum += $HeaderBuffer[$i]
        }
    }

    if ($expectedChecksum -ne $actualChecksum) {
        throw "Invalid tar header checksum."
    }

    $name = Get-TarAsciiField -Bytes $HeaderBuffer -Offset 0 -Length 100
    $prefix = Get-TarAsciiField -Bytes $HeaderBuffer -Offset 345 -Length 155
    if (-not [string]::IsNullOrWhiteSpace($prefix)) {
        $name = $prefix.TrimEnd("/") + "/" + $name.TrimStart("/")
    }

    $typeByte = $HeaderBuffer[156]
    $typeFlag = if ($typeByte -eq 0) { "0" } else { [string][char]$typeByte }
    $size = ConvertFrom-TarSizeField -Bytes $HeaderBuffer

    return [pscustomobject]@{
        IsEnd = $false
        Name = (Normalize-TarPath -Path $name)
        TypeFlag = $typeFlag
        Size = $size
    }
}

# tar 内のパスが安全な相対パスであることを保証する。
function Normalize-TarPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalized = $Path.Replace("\", "/")
    while ($normalized.StartsWith("./", [System.StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(2)
    }

    $normalized = $normalized.TrimEnd("/")

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw "Tar entry has an empty path."
    }

    if ($normalized.StartsWith("/", [System.StringComparison]::Ordinal) -or $normalized -match "^[A-Za-z]:") {
        throw "Tar entry uses an absolute path: $Path"
    }

    foreach ($part in $normalized.Split("/")) {
        if ($part -eq ".." -or $part.Length -eq 0) {
            throw "Tar entry uses an unsafe path: $Path"
        }
    }

    return $normalized
}

function Test-OciBlobPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return $Path -match "^blobs/sha256/[a-f0-9]{64}$"
}

function Convert-DigestToBlobPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Digest
    )

    if ($Digest -notmatch "^sha256:([a-f0-9]{64})$") {
        throw "Unsupported or invalid OCI digest: $Digest"
    }

    return "blobs/sha256/" + $Matches[1]
}

# 小さな JSON メタデータはメモリに保持し、巨大な layer blob は読み捨てる。
# blobs/sha256 以下は読みながら SHA256 を計算し、パス名の digest と一致するか検証する。
function Read-TarEntryPayload {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Stream]$Stream,

        [Parameter(Mandatory = $true)]
        [Int64]$Size,

        [Parameter(Mandatory = $true)]
        [bool]$Capture,

        [AllowNull()]
        [string]$ExpectedSha256,

        [Parameter(Mandatory = $true)]
        [byte[]]$Buffer
    )

    $memory = $null
    if ($Capture) {
        $memory = New-Object System.IO.MemoryStream
    }

    $sha256 = $null
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
    }

    try {
        $remaining = $Size
        while ($remaining -gt 0) {
            $readLength = if ($remaining -lt [Int64]$Buffer.Length) { $remaining } else { [Int64]$Buffer.Length }
            $bytesRead = $Stream.Read($Buffer, 0, [int]$readLength)
            if ($bytesRead -le 0) {
                throw "Unexpected end of tar stream while reading payload."
            }

            if ($Capture) {
                $memory.Write($Buffer, 0, $bytesRead)
            }

            if ($null -ne $sha256) {
                [void]$sha256.TransformBlock($Buffer, 0, $bytesRead, $Buffer, 0)
            }

            $remaining -= $bytesRead
        }

        $hashHex = $null
        if ($null -ne $sha256) {
            $empty = New-Object byte[] 0
            [void]$sha256.TransformFinalBlock($empty, 0, 0)
            $hashHex = -join ($sha256.Hash | ForEach-Object { $_.ToString("x2") })
            if ($hashHex -ne $ExpectedSha256) {
                throw "OCI blob digest mismatch: expected sha256:$ExpectedSha256, actual sha256:$hashHex."
            }
        }

        $padding = (512 - ($Size % 512)) % 512
        if ($padding -gt 0) {
            Read-StreamDiscard -Stream $Stream -Count $padding -Buffer $Buffer
        }

        $capturedBytes = $null
        if ($Capture) {
            $capturedBytes = $memory.ToArray()
        }

        return [pscustomobject]@{
            Bytes = $capturedBytes
            Sha256 = $hashHex
        }
    }
    finally {
        if ($null -ne $memory) {
            $memory.Dispose()
        }

        if ($null -ne $sha256) {
            $sha256.Dispose()
        }
    }
}

function ConvertFrom-CapturedJson {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$CapturedFiles,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not $CapturedFiles.ContainsKey($Path)) {
        throw "Required OCI metadata was not captured: $Path"
    }

    $text = [System.Text.Encoding]::UTF8.GetString($CapturedFiles[$Path])
    try {
        return ConvertFrom-Json -InputObject $text
    }
    catch {
        throw "Invalid JSON in ${Path}: $($_.Exception.Message)"
    }
}

function Assert-OciEntryExists {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Entries,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not $Entries.ContainsKey($Path)) {
        throw "OCI referenced file is missing from tar: $Path"
    }
}

function Assert-OciSizeMatches {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Entries,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [AllowNull()]
        $ExpectedSize
    )

    if ($null -eq $ExpectedSize) {
        return
    }

    $expected = [Int64]$ExpectedSize
    $actual = [Int64]$Entries[$Path].Size
    if ($expected -ne $actual) {
        throw "OCI size mismatch for ${Path}: manifest=$expected tar=$actual"
    }
}

function Get-JsonPropertyValue {
    param(
        [AllowNull()]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $properties = @($Object.PSObject.Properties.Match($Name))
    if ($properties.Count -eq 0) {
        return $null
    }

    return $properties[0].Value
}

function Test-OciLayerMediaType {
    param(
        [AllowNull()]
        [string]$MediaType
    )

    if ([string]::IsNullOrWhiteSpace($MediaType)) {
        return $false
    }

    return $MediaType -match "^application/vnd\.(oci\.image\.layer(\.nondistributable)?\.v1\.tar(\+(gzip|zstd))?|docker\.image\.rootfs\.diff\.tar(\.gzip)?|in-toto\+json)$"
}

function Assert-OciDescriptorGraph {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Entries,

        [Parameter(Mandatory = $true)]
        [hashtable]$CapturedFiles,

        [Parameter(Mandatory = $true)]
        $Descriptor,

        [Parameter(Mandatory = $true)]
        [hashtable]$Visited
    )

    $descriptorDigest = [string](Get-JsonPropertyValue -Object $Descriptor -Name "digest")
    if ([string]::IsNullOrWhiteSpace($descriptorDigest)) {
        throw "OCI descriptor does not contain a digest."
    }

    $descriptorPath = Convert-DigestToBlobPath -Digest $descriptorDigest
    Assert-OciEntryExists -Entries $Entries -Path $descriptorPath
    Assert-OciSizeMatches -Entries $Entries -Path $descriptorPath -ExpectedSize (Get-JsonPropertyValue -Object $Descriptor -Name "size")

    if ($Visited.ContainsKey($descriptorPath)) {
        return
    }
    $Visited[$descriptorPath] = $true

    $node = ConvertFrom-CapturedJson -CapturedFiles $CapturedFiles -Path $descriptorPath
    if ([int](Get-JsonPropertyValue -Object $node -Name "schemaVersion") -ne 2) {
        throw "$descriptorPath has unsupported schemaVersion: $(Get-JsonPropertyValue -Object $node -Name "schemaVersion")"
    }

    $childManifests = Get-JsonPropertyValue -Object $node -Name "manifests"
    if ($null -ne $childManifests) {
        # index.json からさらに OCI image index / Docker manifest list を指す場合がある。
        foreach ($childDescriptor in @($childManifests)) {
            Assert-OciDescriptorGraph `
                -Entries $Entries `
                -CapturedFiles $CapturedFiles `
                -Descriptor $childDescriptor `
                -Visited $Visited
        }
        return
    }

    $config = Get-JsonPropertyValue -Object $node -Name "config"
    $configDigest = [string](Get-JsonPropertyValue -Object $config -Name "digest")
    if ([string]::IsNullOrWhiteSpace($configDigest)) {
        throw "$descriptorPath does not contain a config digest."
    }

    $configPath = Convert-DigestToBlobPath -Digest $configDigest
    Assert-OciEntryExists -Entries $Entries -Path $configPath
    Assert-OciSizeMatches -Entries $Entries -Path $configPath -ExpectedSize (Get-JsonPropertyValue -Object $config -Name "size")

    $layersValue = Get-JsonPropertyValue -Object $node -Name "layers"
    if ($null -eq $layersValue) {
        throw "$descriptorPath does not contain a layers array."
    }

    foreach ($layer in @($layersValue)) {
        $layerDigest = [string](Get-JsonPropertyValue -Object $layer -Name "digest")
        if ([string]::IsNullOrWhiteSpace($layerDigest)) {
            throw "$descriptorPath contains a layer without digest."
        }

        $layerPath = Convert-DigestToBlobPath -Digest $layerDigest
        Assert-OciEntryExists -Entries $Entries -Path $layerPath
        Assert-OciSizeMatches -Entries $Entries -Path $layerPath -ExpectedSize (Get-JsonPropertyValue -Object $layer -Name "size")

        $mediaType = [string](Get-JsonPropertyValue -Object $layer -Name "mediaType")
        if (-not (Test-OciLayerMediaType -MediaType $mediaType)) {
            throw "Unsupported OCI layer mediaType for ${layerPath}: $mediaType"
        }
    }
}

# 読み取った tar 構造と JSON メタデータの参照関係をまとめて検証する。
function Assert-OciExportState {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Entries,

        [Parameter(Mandatory = $true)]
        [hashtable]$CapturedFiles
    )

    Assert-OciEntryExists -Entries $Entries -Path "oci-layout"
    Assert-OciEntryExists -Entries $Entries -Path "index.json"

    $layout = ConvertFrom-CapturedJson -CapturedFiles $CapturedFiles -Path "oci-layout"
    if ($layout.imageLayoutVersion -ne "1.0.0") {
        throw "Unsupported OCI layout version: $($layout.imageLayoutVersion)"
    }

    $index = ConvertFrom-CapturedJson -CapturedFiles $CapturedFiles -Path "index.json"
    if ([int]$index.schemaVersion -ne 2) {
        throw "index.json has unsupported schemaVersion: $($index.schemaVersion)"
    }

    $indexManifestsValue = Get-JsonPropertyValue -Object $index -Name "manifests"
    $indexManifests = @($indexManifestsValue)
    if ($null -eq $indexManifestsValue -or $indexManifests.Count -eq 0) {
        throw "index.json does not contain any manifests."
    }

    $visitedDescriptors = @{}
    foreach ($indexManifest in $indexManifests) {
        Assert-OciDescriptorGraph `
            -Entries $Entries `
            -CapturedFiles $CapturedFiles `
            -Descriptor $indexManifest `
            -Visited $visitedDescriptors
    }

    # regctl の export は環境や対象によって Docker 互換 manifest.json を含む場合と、
    # 純粋な OCI layout の index.json + blobs だけになる場合がある。
    # OCI layout としては manifest.json は必須ではないため、存在する場合だけ追加検証する。
    if (-not $CapturedFiles.ContainsKey("manifest.json")) {
        return
    }

    $dockerManifest = @(ConvertFrom-CapturedJson -CapturedFiles $CapturedFiles -Path "manifest.json")
    if ($dockerManifest.Count -eq 0) {
        throw "manifest.json does not contain docker load metadata."
    }

    foreach ($item in $dockerManifest) {
        if ([string]::IsNullOrWhiteSpace([string]$item.Config)) {
            throw "manifest.json contains an item without Config."
        }

        $configPath = Normalize-TarPath -Path ([string]$item.Config)
        if (-not (Test-OciBlobPath -Path $configPath)) {
            throw "manifest.json Config is not an OCI blob path: $configPath"
        }
        Assert-OciEntryExists -Entries $Entries -Path $configPath

        $layers = @($item.Layers)
        if ($null -eq $item.Layers) {
            throw "manifest.json contains an item without Layers."
        }

        foreach ($layerPathRaw in $layers) {
            $layerPath = Normalize-TarPath -Path ([string]$layerPathRaw)
            if (-not (Test-OciBlobPath -Path $layerPath)) {
                throw "manifest.json Layer is not an OCI blob path: $layerPath"
            }

            Assert-OciEntryExists -Entries $Entries -Path $layerPath

            $layerDigest = "sha256:" + ($layerPath.Substring("blobs/sha256/".Length))
            if ($null -ne $item.LayerSources) {
                $sourceProperties = @($item.LayerSources.PSObject.Properties.Match($layerDigest))
                if ($sourceProperties.Count -gt 0) {
                    $source = $sourceProperties[0].Value
                    Assert-OciSizeMatches -Entries $Entries -Path $layerPath -ExpectedSize $source.size
                    if ([string]$source.digest -ne $layerDigest) {
                        throw "LayerSources digest mismatch for $layerPath."
                    }
                }
            }
        }
    }
}

# 分割前の検証パス。tar を保存せずに全体を読み、OCI 形式と blob digest を確認する。
function Invoke-OciExportValidation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedRegctlPath,

        [Parameter(Mandatory = $true)]
        [string]$Reference,

        [Parameter(Mandatory = $true)]
        [int]$MetadataMaxMB
    )

    $process = New-RegctlExportProcess -ResolvedRegctlPath $ResolvedRegctlPath -Reference $Reference
    $processStarted = $false

    $headerBuffer = New-Object byte[] 512
    $payloadBuffer = New-Object byte[] 1048576
    $metadataMaxBytes = [Int64]$MetadataMaxMB * 1MB
    $metadataTotalMaxBytes = [Int64]128 * 1MB
    $metadataTotalBytes = [Int64]0
    $entries = @{}
    $capturedFiles = @{}
    $totalBytes = [Int64]0
    $nextProgressAt = [Int64]1GB

    try {
        Write-Host ("OCI validation start: {0}" -f $Reference)
        if (-not $process.Start()) {
            throw "Failed to start regctl for OCI validation."
        }
        $processStarted = $true

        $stdout = $process.StandardOutput.BaseStream
        while ($true) {
            $entry = Read-TarHeader -Stream $stdout -HeaderBuffer $headerBuffer
            if ($null -eq $entry) {
                throw "Tar stream ended without an end marker."
            }

            if ($entry.IsEnd) {
                break
            }

            if ($entries.ContainsKey($entry.Name)) {
                throw "Duplicate tar entry found: $($entry.Name)"
            }

            $isRegularFile = ($entry.TypeFlag -eq "0")
            $entries[$entry.Name] = [pscustomobject]@{
                TypeFlag = $entry.TypeFlag
                Size = $entry.Size
            }

            $expectedSha = $null
            if (Test-OciBlobPath -Path $entry.Name) {
                $expectedSha = $entry.Name.Substring("blobs/sha256/".Length)
            }

            $capture = $false
            if ($isRegularFile) {
                $isRequiredTopLevelJson = @("oci-layout", "index.json", "manifest.json") -contains $entry.Name
                $isSmallBlob = (Test-OciBlobPath -Path $entry.Name) -and $entry.Size -le $metadataMaxBytes
                if ($isRequiredTopLevelJson -or $isSmallBlob) {
                    if (($metadataTotalBytes + $entry.Size) -gt $metadataTotalMaxBytes) {
                        throw "Too much OCI metadata to keep in memory. Increase limits only after checking the image."
                    }

                    $capture = $true
                    $metadataTotalBytes += $entry.Size
                }
            }

            $payloadResult = Read-TarEntryPayload `
                -Stream $stdout `
                -Size $entry.Size `
                -Capture $capture `
                -ExpectedSha256 $expectedSha `
                -Buffer $payloadBuffer

            if ($capture) {
                $capturedFiles[$entry.Name] = $payloadResult.Bytes
            }

            $totalBytes += 512 + $entry.Size + ((512 - ($entry.Size % 512)) % 512)
            if ($totalBytes -ge $nextProgressAt) {
                Write-Host ("OCI validation: {0} GB scanned" -f (Format-Gigabytes $totalBytes))
                while ($nextProgressAt -le $totalBytes) {
                    $nextProgressAt += [Int64]1GB
                }
            }
        }

        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "OCI validation export failed. regctl exited with code $($process.ExitCode)."
        }

        Assert-OciExportState -Entries $entries -CapturedFiles $capturedFiles
        Write-Host ("OCI validation complete: {0} GB scanned" -f (Format-Gigabytes $totalBytes))
    }
    finally {
        if ($processStarted -and $null -ne $process -and -not $process.HasExited) {
            try {
                $process.Kill()
                $process.WaitForExit()
            }
            catch {
                Write-Warning ("Failed to stop regctl validation process: {0}" -f $_.Exception.Message)
            }
        }

        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Format-Megabytes {
    param([Int64]$Bytes)
    return "{0:N2}" -f ($Bytes / 1MB)
}

function Format-Gigabytes {
    param([Int64]$Bytes)
    return "{0:N2}" -f ($Bytes / 1GB)
}

function Write-PartStatus {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PartNumber,

        [Parameter(Mandatory = $true)]
        [Int64]$PartBytes,

        [Parameter(Mandatory = $true)]
        [Int64]$TotalBytes,

        [Parameter(Mandatory = $true)]
        [Int64]$PartSizeBytes
    )

    $percent = [Math]::Min(100, [Math]::Floor(($PartBytes * 100.0) / $PartSizeBytes))
    $status = "Part {0}: {1} MB written; total {2} GB received" -f `
        $PartNumber, (Format-Megabytes $PartBytes), (Format-Gigabytes $TotalBytes)

    Write-Progress -Activity "regctl image export" -Status $status -PercentComplete $percent
    Write-Host $status
}

function Get-StatePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    return (Join-Path -Path $Directory -ChildPath ".download-state.json")
}

function Get-PartPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [string]$FileBase,

        [Parameter(Mandatory = $true)]
        [int]$PartNumber
    )

    return (Join-Path -Path $Directory -ChildPath ("{0}_Part{1}.tar" -f $FileBase, $PartNumber))
}

function New-DownloadState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reference,

        [Parameter(Mandatory = $true)]
        [string]$FileBase,

        [Parameter(Mandatory = $true)]
        [Int64]$PartSizeBytes
    )

    return [pscustomobject]@{
        Version = 1
        ImageRef = $Reference
        FileBase = $FileBase
        PartSizeBytes = $PartSizeBytes
        BytesCompleted = [Int64]0
        NextPartNumber = 1
        PendingPartNumber = $null
        PendingBytes = [Int64]0
        PendingIsFinal = $false
        Completed = $false
        OciValidated = $false
        CreatedAt = [DateTime]::UtcNow.ToString("o")
        UpdatedAt = [DateTime]::UtcNow.ToString("o")
    }
}

function Read-DownloadState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath,

        [Parameter(Mandatory = $true)]
        [string]$Reference,

        [Parameter(Mandatory = $true)]
        [string]$FileBase,

        [Parameter(Mandatory = $true)]
        [Int64]$PartSizeBytes
    )

    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        return (New-DownloadState -Reference $Reference -FileBase $FileBase -PartSizeBytes $PartSizeBytes)
    }

    $state = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
    if ($state.Version -ne 1) {
        throw "Unsupported state file version: $($state.Version)"
    }

    if ([string]$state.ImageRef -ne $Reference) {
        throw "State ImageRef does not match. State='$($state.ImageRef)' Current='$Reference'"
    }

    if ([Int64]$state.PartSizeBytes -ne $PartSizeBytes) {
        throw "PartSizeGB differs from the existing state. Use the same PartSizeGB or run with -ResetState."
    }

    return $state
}

function Save-DownloadState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,

        [Parameter(Mandatory = $true)]
        [string]$StatePath
    )

    $State.UpdatedAt = [DateTime]::UtcNow.ToString("o")
    $json = $State | ConvertTo-Json -Depth 5
    $tmpPath = $StatePath + ".tmp"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
    Move-Item -LiteralPath $tmpPath -Destination $StatePath -Force
}

function Commit-PendingPartIfMoved {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,

        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory,

        [Parameter(Mandatory = $true)]
        [string]$StatePath
    )

    if ($null -eq $State.PendingPartNumber) {
        return
    }

    $pendingPath = Get-PartPath `
        -Directory $OutputDirectory `
        -FileBase ([string]$State.FileBase) `
        -PartNumber ([int]$State.PendingPartNumber)

    if (Test-Path -LiteralPath $pendingPath -PathType Leaf) {
        throw "Part$($State.PendingPartNumber) still exists locally. Move it to the file server, then run download.ps1 again: $pendingPath"
    }

    # pending Part がローカルから消えていれば、ユーザが手動搬送したものとして state を進める。
    $State.BytesCompleted = [Int64]$State.BytesCompleted + [Int64]$State.PendingBytes
    if ([bool]$State.PendingIsFinal) {
        $State.Completed = $true
    }
    else {
        $State.NextPartNumber = [int]$State.PendingPartNumber + 1
    }

    $State.PendingPartNumber = $null
    $State.PendingBytes = [Int64]0
    $State.PendingIsFinal = $false
    Save-DownloadState -State $State -StatePath $StatePath
}

function Close-PartStream {
    param(
        [AllowNull()]
        [System.IO.FileStream]$Stream
    )

    if ($null -ne $Stream) {
        $Stream.Flush()
        $Stream.Dispose()
    }
}

function Invoke-Main {
    $resolvedRegctlPath = Resolve-ExecutablePath -Path $RegctlPath

    $fileBase = Get-ImageFileBase -Reference $ImageRef
    $partSizeBytes = [Int64][Math]::Ceiling($PartSizeGB * 1GB)
    $progressIntervalBytes = [Int64]$ProgressIntervalMB * 1MB
    $buffer = New-Object byte[] 1048576

    # download.ps1 直下にイメージ名+タグのサブディレクトリを作り、Part と state はそこだけに置く。
    $resolvedOutputRoot = (Resolve-Path -LiteralPath $ScriptDirectory).ProviderPath
    $imageOutputDir = Join-Path -Path $resolvedOutputRoot -ChildPath $fileBase
    $createdImageDir = New-Item -ItemType Directory -Path $imageOutputDir -Force
    $resolvedOutputDir = (Resolve-Path -LiteralPath $createdImageDir.FullName).ProviderPath
    $statePath = Get-StatePath -Directory $resolvedOutputDir

    if ($ResetState) {
        $existingPartsForReset = @(Get-ChildItem -LiteralPath $resolvedOutputDir -Filter ($fileBase + "_Part*.tar") -File -ErrorAction SilentlyContinue)
        if ($existingPartsForReset.Count -gt 0) {
            throw "-ResetState was requested, but Part files still exist in '$resolvedOutputDir'. Move or delete them first."
        }

        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        Write-Host ("State reset: {0}" -f $statePath)
    }

    $state = Read-DownloadState `
        -StatePath $statePath `
        -Reference $ImageRef `
        -FileBase $fileBase `
        -PartSizeBytes $partSizeBytes

    Save-DownloadState -State $state -StatePath $statePath

    # 前回作成した pending Part が消えていれば、手動搬送済みと見なして state を進める。
    Commit-PendingPartIfMoved -State $state -OutputDirectory $resolvedOutputDir -StatePath $statePath

    if ([bool]$state.Completed) {
        Write-Host ("Download is already complete for: {0}" -f $ImageRef)
        Write-Host ("Parts directory: {0}" -f $resolvedOutputDir)
        return
    }

    # pending 以外の Part がローカルに残っている場合も、次の Part を作ると quota を圧迫するので止める。
    $remainingParts = @(Get-ChildItem -LiteralPath $resolvedOutputDir -Filter ($fileBase + "_Part*.tar") -File -ErrorAction SilentlyContinue)
    if ($remainingParts.Count -gt 0) {
        $names = ($remainingParts | Select-Object -ExpandProperty Name) -join ", "
        throw "Part files still exist locally. Move them to the file server before rerunning: $names"
    }

    # OCI 検証は初回だけ行う。以降の Part では state に記録された結果を使う。
    if (-not $SkipOciValidation -and -not [bool]$state.OciValidated) {
        Invoke-WithRegctlRetry -OperationName "OCI validation" -ScriptBlock {
            Invoke-OciExportValidation `
                -ResolvedRegctlPath $resolvedRegctlPath `
                -Reference $ImageRef `
                -MetadataMaxMB $OciMetadataMaxMB
        }

        $state.OciValidated = $true
        Save-DownloadState -State $state -StatePath $statePath
    }
    elseif ($SkipOciValidation -and -not [bool]$state.OciValidated) {
        Write-Warning "OCI validation was skipped by -SkipOciValidation."
    }

    $partNumber = [int]$state.NextPartNumber
    $partPath = Get-PartPath -Directory $resolvedOutputDir -FileBase $fileBase -PartNumber $partNumber

    for ($attempt = 1; $attempt -le $script:RegctlMaxAttempts; $attempt++) {
        $process = New-RegctlExportProcess -ResolvedRegctlPath $resolvedRegctlPath -Reference $ImageRef
        $processStarted = $false

        # 再試行時は state の完了済みバイトから読み捨てをやり直す。
        $bytesToSkip = [Int64]$state.BytesCompleted
        $skippedBytes = [Int64]0
        $currentPartBytes = [Int64]0
        $totalBytes = $bytesToSkip
        $nextProgressAt = $progressIntervalBytes
        $partStream = $null
        $partReachedSize = $false
        $attemptFailed = $false
        $retryAfterCleanup = $false
        $exportSucceeded = $false

        try {
            if ($attempt -gt 1) {
                Write-Host ("Retry export attempt {0}/{1}" -f $attempt, $script:RegctlMaxAttempts)
            }

            Write-Host ("Start export: {0}" -f $ImageRef)
            Write-Host ("regctl: {0}" -f $resolvedRegctlPath)
            Write-Host ("OutputDir: {0}" -f $resolvedOutputDir)
            Write-Host ("State: {0}" -f $statePath)
            Write-Host ("PartSize: {0:N2} GB" -f $PartSizeGB)
            Write-Host ("NextPart: Part{0}" -f $partNumber)
            if ($bytesToSkip -gt 0) {
                Write-Host ("Skip already completed bytes: {0} GB" -f (Format-Gigabytes $bytesToSkip))
            }

            if (-not $process.Start()) {
                throw "Failed to start regctl."
            }
            $processStarted = $true

            $stdout = $process.StandardOutput.BaseStream

            while ($bytesToSkip -gt 0) {
                $readLength = if ($bytesToSkip -lt [Int64]$buffer.Length) { $bytesToSkip } else { [Int64]$buffer.Length }
                $bytesRead = $stdout.Read($buffer, 0, [int]$readLength)

                if ($bytesRead -le 0) {
                    $process.WaitForExit()
                    if ($process.ExitCode -eq 0) {
                        $state.Completed = $true
                        Save-DownloadState -State $state -StatePath $statePath
                        Write-Host "No more bytes are available. Download marked complete."
                        return
                    }

                    throw "Export ended before the state offset. regctl exited with code $($process.ExitCode)."
                }

                $bytesToSkip -= $bytesRead
                $skippedBytes += $bytesRead

                if ($skippedBytes -ge $nextProgressAt) {
                    Write-Host ("Skip progress: {0} GB skipped" -f (Format-Gigabytes $skippedBytes))
                    while ($nextProgressAt -le $skippedBytes) {
                        $nextProgressAt += $progressIntervalBytes
                    }
                }
            }

            Write-Host ("Part {0} start: {1}" -f $partNumber, $partPath)
            # CreateNew にして、同名 Part の上書きによる復旧不能な混在を避ける。
            $partStream = [System.IO.File]::Open(
                $partPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
            $nextProgressAt = $progressIntervalBytes

            while ($true) {
                # 現在 Part の残容量を超えて読まないことで、Part サイズを固定する。
                $remainingInPart = $partSizeBytes - $currentPartBytes
                $readLength = if ($remainingInPart -lt [Int64]$buffer.Length) { $remainingInPart } else { [Int64]$buffer.Length }
                $bytesRead = $stdout.Read($buffer, 0, [int]$readLength)

                if ($bytesRead -le 0) {
                    break
                }

                $partStream.Write($buffer, 0, $bytesRead)
                $currentPartBytes += $bytesRead
                $totalBytes += $bytesRead

                if ($currentPartBytes -ge $nextProgressAt -or $currentPartBytes -eq $partSizeBytes) {
                    Write-PartStatus `
                        -PartNumber $partNumber `
                        -PartBytes $currentPartBytes `
                        -TotalBytes $totalBytes `
                        -PartSizeBytes $partSizeBytes

                    while ($nextProgressAt -le $currentPartBytes) {
                        $nextProgressAt += $progressIntervalBytes
                    }
                }

                if ($currentPartBytes -eq $partSizeBytes) {
                    $partReachedSize = $true
                    break
                }
            }

            if ($null -ne $partStream) {
                Close-PartStream -Stream $partStream
                $partStream = $null

                if ($currentPartBytes -le 0) {
                    Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
                    Write-Host ("Empty part deleted: {0}" -f $partPath)
                    $partPath = $null
                }
            }

            if ($currentPartBytes -le 0) {
                Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
                $process.WaitForExit()
                Write-Progress -Activity "regctl image export" -Completed

                if ($process.ExitCode -ne 0) {
                    throw "Export failed. regctl exited with code $($process.ExitCode)."
                }

                $state.Completed = $true
                Save-DownloadState -State $state -StatePath $statePath
                Write-Host "No more bytes are available. Download marked complete."
                return
            }

            if (-not $partReachedSize) {
                # PartSizeGB 未満で EOF になった場合は最終 Part。regctl の正常終了を確認してから state に残す。
                $process.WaitForExit()
                Write-Progress -Activity "regctl image export" -Completed

                if ($process.ExitCode -ne 0) {
                    throw "Export failed. regctl exited with code $($process.ExitCode)."
                }
            }
            else {
                # Part が指定サイズに達したら、regctl はまだ出力中なので finally で停止する。
                Write-Progress -Activity "regctl image export" -Completed
            }

            $state.PendingPartNumber = $partNumber
            $state.PendingBytes = [Int64]$currentPartBytes
            $state.PendingIsFinal = (-not $partReachedSize)
            Save-DownloadState -State $state -StatePath $statePath

            Write-Host ("Part {0} created: {1}" -f $partNumber, $partPath)
            Write-Host ("Part size: {0} MB" -f (Format-Megabytes $currentPartBytes))
            Write-Host "Move this Part file to the Samba file server manually, then run download.ps1 again."
            $exportSucceeded = $true
        }
        catch {
            $attemptFailed = $true
            $message = $_.Exception.Message
            $retryAfterCleanup = ($attempt -lt $script:RegctlMaxAttempts -and (Test-RegctlTransientError -Message $message))

            if ($retryAfterCleanup) {
                Write-Warning ("regctl export failed on attempt {0}/{1}: {2}" -f $attempt, $script:RegctlMaxAttempts, $message)
            }
            else {
                throw
            }
        }
        finally {
            Close-PartStream -Stream $partStream
            Write-Progress -Activity "regctl image export" -Completed

            if ($processStarted -and $null -ne $process -and -not $process.HasExited) {
                try {
                    $process.Kill()
                    $process.WaitForExit()
                }
                catch {
                    Write-Warning ("Failed to stop regctl process: {0}" -f $_.Exception.Message)
                }
            }

            if ($null -ne $process) {
                $process.Dispose()
            }

            if ($attemptFailed -and $null -ne $partPath -and (Test-Path -LiteralPath $partPath -PathType Leaf)) {
                Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
                Write-Warning ("Partial part deleted after failed attempt: {0}" -f $partPath)
            }
            elseif ($null -ne $partPath -and (Test-Path -LiteralPath $partPath -PathType Leaf)) {
                $partInfo = Get-Item -LiteralPath $partPath
                if ($partInfo.Length -eq 0) {
                    Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
                    Write-Host ("Empty part deleted: {0}" -f $partPath)
                }
            }
        }

        if ($exportSucceeded) {
            return
        }

        if ($retryAfterCleanup -and $script:RegctlRetryDelaySeconds -gt 0) {
            Start-Sleep -Seconds $script:RegctlRetryDelaySeconds
        }
    }
}

try {
    Invoke-Main
}
catch {
    [Console]::Error.WriteLine(("ERROR: {0}" -f $_.Exception.Message))
    exit 1
}
