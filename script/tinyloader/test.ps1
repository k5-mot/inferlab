[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$ImageRef,

    [switch]$KeepWorkDir,

    [string]$RegctlPath = ".\regctl.exe",

    [ValidateScript({ $_ -gt 0 })]
    [double]$PartSizeGB = 4,

    [switch]$SkipOciValidation
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# 引数なしの場合は完全オフラインの自己テストを行う。
# ImageRef を渡した場合は実際の regctl export を使い、任意イメージの分割と merge を検証する。
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$DownloadScript = Join-Path $RepoRoot "download.ps1"
$MergeScript = Join-Path $RepoRoot "merge.sh"
$WorkRoot = Join-Path $RepoRoot "_test_work"

# PowerShell 5.1 でも使える最小限の assert。
function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

# テスト作業ディレクトリだけを安全に削除する。
function Remove-TestWorkRoot {
    if (-not (Test-Path -LiteralPath $WorkRoot)) {
        return
    }

    $repoResolved = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $workResolved = (Resolve-Path -LiteralPath $WorkRoot).ProviderPath
    Assert-True `
        -Condition $workResolved.StartsWith($repoResolved, [System.StringComparison]::OrdinalIgnoreCase) `
        -Message "Refusing to remove a path outside the repository: $workResolved"

    Remove-Item -LiteralPath $workResolved -Recurse -Force
}

function New-Utf8NoBomEncoding {
    return New-Object System.Text.UTF8Encoding($false)
}

# OCI JSON は digest 計算対象なので、BOM なし UTF-8 に固定する。
function ConvertTo-Utf8Bytes {
    param([Parameter(Mandatory = $true)][string]$Text)
    return (New-Utf8NoBomEncoding).GetBytes($Text)
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha256.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") })
    }
    finally {
        $sha256.Dispose()
    }
}

# 生成物同士を比較するため、ファイル全体の SHA256 を計算する。
function Get-FileSha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        return -join ($sha256.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") })
    }
    finally {
        $stream.Dispose()
        $sha256.Dispose()
    }
}

# 複数 Part をメモリに積まず、連結した場合の SHA256 をストリーム計算する。
function Get-ConcatenatedFilesSha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo[]]$Files
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $buffer = New-Object byte[] 1048576
    try {
        foreach ($file in $Files) {
            $stream = [System.IO.File]::OpenRead($file.FullName)
            try {
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    [void]$sha256.TransformBlock($buffer, 0, $read, $buffer, 0)
                }
            }
            finally {
                $stream.Dispose()
            }
        }

        $empty = New-Object byte[] 0
        [void]$sha256.TransformFinalBlock($empty, 0, 0)
        return -join ($sha256.Hash | ForEach-Object { $_.ToString("x2") })
    }
    finally {
        $sha256.Dispose()
    }
}

# download.ps1 と同じルールで ImageRef から Part 名ベースを作る。
function Get-ImageFileBaseForTest {
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

# Part10 が Part2 より前に来ないよう、ファイル名から数値を抜いて並べる。
function Get-PartFilesForBase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [string]$FileBase
    )

    $prefix = "${FileBase}_Part"
    $files = Get-ChildItem -LiteralPath $Directory -Filter "${FileBase}_Part*.tar" -File -ErrorAction SilentlyContinue
    return @(
        $files |
            ForEach-Object {
                $numberText = $_.BaseName.Substring($prefix.Length)
                if ($numberText -match "^[0-9]+$") {
                    [pscustomobject]@{
                        File = $_
                        Number = [int]$numberText
                    }
                }
            } |
            Sort-Object Number |
            ForEach-Object { $_.File }
    )
}

# test.ps1 をどこから実行しても regctl.exe を見つけやすいよう、repo 相対も見る。
function Resolve-TestExecutablePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Path).ProviderPath
    }

    $repoRelative = Join-Path $RepoRoot $Path
    if (Test-Path -LiteralPath $repoRelative -PathType Leaf) {
        return (Resolve-Path -LiteralPath $repoRelative).ProviderPath
    }

    $command = Get-Command -Name $Path -ErrorAction SilentlyContinue
    if ($null -ne $command -and $null -ne $command.Source) {
        return $command.Source
    }

    throw "Executable was not found: $Path"
}

# テスト tar を自前で生成するための tar header 書き込みヘルパー。
function Write-AsciiField {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Header,

        [Parameter(Mandatory = $true)]
        [int]$Offset,

        [Parameter(Mandatory = $true)]
        [int]$Length,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Value)
    Assert-True -Condition ($bytes.Length -le $Length) -Message "tar field is too long: $Value"
    [Array]::Copy($bytes, 0, $Header, $Offset, $bytes.Length)
}

# POSIX tar の 512 byte header を作る。テスト用途に必要な最小フィールドだけを埋める。
function New-TarHeader {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [Int64]$Size,

        [Parameter(Mandatory = $true)]
        [string]$TypeFlag
    )

    Assert-True -Condition ($Name.Length -le 100) -Message "test tar path is too long: $Name"

    $header = New-Object byte[] 512
    Write-AsciiField -Header $header -Offset 0 -Length 100 -Value $Name
    Write-AsciiField -Header $header -Offset 100 -Length 8 -Value "0000644`0"
    Write-AsciiField -Header $header -Offset 108 -Length 8 -Value "0000000`0"
    Write-AsciiField -Header $header -Offset 116 -Length 8 -Value "0000000`0"
    Write-AsciiField -Header $header -Offset 124 -Length 12 -Value (([Convert]::ToString($Size, 8)).PadLeft(11, "0") + "`0")
    Write-AsciiField -Header $header -Offset 136 -Length 12 -Value "00000000000`0"
    for ($i = 148; $i -lt 156; $i++) {
        $header[$i] = 32
    }
    Write-AsciiField -Header $header -Offset 156 -Length 1 -Value $TypeFlag
    Write-AsciiField -Header $header -Offset 257 -Length 6 -Value "ustar`0"
    Write-AsciiField -Header $header -Offset 263 -Length 2 -Value "00"

    [Int64]$checksum = 0
    foreach ($byte in $header) {
        $checksum += $byte
    }

    Write-AsciiField -Header $header -Offset 148 -Length 8 -Value (([Convert]::ToString($checksum, 8)).PadLeft(6, "0") + "`0 ")
    return $header
}

# tar へ 1 エントリ追加する。OCI layout の directory entry もここで作る。
function Add-TarEntry {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Stream]$Stream,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Content,

        [string]$TypeFlag = "0"
    )

    $size = if ($TypeFlag -eq "0") { [Int64]$Content.Length } else { [Int64]0 }
    $header = New-TarHeader -Name $Name -Size $size -TypeFlag $TypeFlag
    $Stream.Write($header, 0, $header.Length)

    if ($TypeFlag -eq "0" -and $Content.Length -gt 0) {
        $Stream.Write($Content, 0, $Content.Length)
        $padding = (512 - ($Content.Length % 512)) % 512
        if ($padding -gt 0) {
            $zeros = New-Object byte[] $padding
            $Stream.Write($zeros, 0, $zeros.Length)
        }
    }
}

# regctl が出力する docker load 互換 OCI layout に近い、最小テスト tar を作る。
function New-TestOciTar {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TarPath
    )

    $emptyLayerTar = New-Object byte[] 1024
    $layerDigest = Get-Sha256Hex -Bytes $emptyLayerTar

    $configJson = "{""architecture"":""amd64"",""os"":""linux"",""rootfs"":{""type"":""layers"",""diff_ids"":[""sha256:$layerDigest""]},""config"":{}}"
    $configBytes = ConvertTo-Utf8Bytes -Text $configJson
    $configDigest = Get-Sha256Hex -Bytes $configBytes

    $imageManifestJson = "{""schemaVersion"":2,""mediaType"":""application/vnd.oci.image.manifest.v1+json"",""config"":{""mediaType"":""application/vnd.oci.image.config.v1+json"",""digest"":""sha256:$configDigest"",""size"":$($configBytes.Length)},""layers"":[{""mediaType"":""application/vnd.oci.image.layer.v1.tar"",""digest"":""sha256:$layerDigest"",""size"":$($emptyLayerTar.Length)}]}"
    $imageManifestBytes = ConvertTo-Utf8Bytes -Text $imageManifestJson
    $imageManifestDigest = Get-Sha256Hex -Bytes $imageManifestBytes

    $attestationBytes = ConvertTo-Utf8Bytes -Text "{""_type"":""https://in-toto.io/Statement/v1"",""predicateType"":""https://slsa.dev/provenance/v0.2"",""subject"":[],""predicate"":{}}"
    $attestationDigest = Get-Sha256Hex -Bytes $attestationBytes
    $attestationConfigJson = "{""architecture"":""unknown"",""os"":""unknown"",""config"":{}}"
    $attestationConfigBytes = ConvertTo-Utf8Bytes -Text $attestationConfigJson
    $attestationConfigDigest = Get-Sha256Hex -Bytes $attestationConfigBytes
    $attestationManifestJson = "{""schemaVersion"":2,""mediaType"":""application/vnd.oci.image.manifest.v1+json"",""config"":{""mediaType"":""application/vnd.oci.image.config.v1+json"",""digest"":""sha256:$attestationConfigDigest"",""size"":$($attestationConfigBytes.Length)},""layers"":[{""mediaType"":""application/vnd.in-toto+json"",""digest"":""sha256:$attestationDigest"",""size"":$($attestationBytes.Length),""annotations"":{""in-toto.io/predicate-type"":""https://slsa.dev/provenance/v0.2""}}]}"
    $attestationManifestBytes = ConvertTo-Utf8Bytes -Text $attestationManifestJson
    $attestationManifestDigest = Get-Sha256Hex -Bytes $attestationManifestBytes

    $ociLayoutBytes = ConvertTo-Utf8Bytes -Text "{""imageLayoutVersion"":""1.0.0""}"
    $indexJson = "{""schemaVersion"":2,""manifests"":[{""mediaType"":""application/vnd.oci.image.manifest.v1+json"",""digest"":""sha256:$imageManifestDigest"",""size"":$($imageManifestBytes.Length),""annotations"":{""org.opencontainers.image.ref.name"":""latest""}},{""mediaType"":""application/vnd.oci.image.manifest.v1+json"",""digest"":""sha256:$attestationManifestDigest"",""size"":$($attestationManifestBytes.Length),""platform"":{""architecture"":""unknown"",""os"":""unknown""},""annotations"":{""vnd.docker.reference.digest"":""sha256:$imageManifestDigest"",""vnd.docker.reference.type"":""attestation-manifest""}}]}"
    $indexBytes = ConvertTo-Utf8Bytes -Text $indexJson
    $dockerManifestJson = "[{""Config"":""blobs/sha256/$configDigest"",""RepoTags"":[""registry.example.com/tinyloader/test-image:v1""],""Layers"":[""blobs/sha256/$layerDigest""],""LayerSources"":{""sha256:$layerDigest"":{""mediaType"":""application/vnd.oci.image.layer.v1.tar"",""digest"":""sha256:$layerDigest"",""size"":$($emptyLayerTar.Length)}}}]"
    $dockerManifestBytes = ConvertTo-Utf8Bytes -Text $dockerManifestJson

    $stream = [System.IO.File]::Open($TarPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        Add-TarEntry -Stream $stream -Name "oci-layout" -Content $ociLayoutBytes
        Add-TarEntry -Stream $stream -Name "index.json" -Content $indexBytes
        Add-TarEntry -Stream $stream -Name "manifest.json" -Content $dockerManifestBytes
        Add-TarEntry -Stream $stream -Name "blobs" -Content (New-Object byte[] 0) -TypeFlag "5"
        Add-TarEntry -Stream $stream -Name "blobs/sha256" -Content (New-Object byte[] 0) -TypeFlag "5"
        Add-TarEntry -Stream $stream -Name "blobs/sha256/$imageManifestDigest" -Content $imageManifestBytes
        Add-TarEntry -Stream $stream -Name "blobs/sha256/$configDigest" -Content $configBytes
        Add-TarEntry -Stream $stream -Name "blobs/sha256/$layerDigest" -Content $emptyLayerTar
        Add-TarEntry -Stream $stream -Name "blobs/sha256/$attestationManifestDigest" -Content $attestationManifestBytes
        Add-TarEntry -Stream $stream -Name "blobs/sha256/$attestationConfigDigest" -Content $attestationConfigBytes
        Add-TarEntry -Stream $stream -Name "blobs/sha256/$attestationDigest" -Content $attestationBytes

        $end = New-Object byte[] 1024
        $stream.Write($end, 0, $end.Length)
    }
    finally {
        $stream.Dispose()
    }
}

# download.ps1 をネットワークなしで検証するための fake regctl。
# image export IMAGE が呼ばれたら、事前生成した tar を stdout に流す。
function New-FakeRegctl {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $fakeCmd = Join-Path $Directory "fake-regctl.cmd"
    $fakePs1 = Join-Path $Directory "fake-regctl.ps1"

    Set-Content -LiteralPath $fakeCmd -Encoding ASCII -Value @(
        "@echo off",
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""%~dp0fake-regctl.ps1"" %*"
    )

    $script = @'
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = "Stop"

if ($Args.Count -lt 3 -or $Args[0] -ne "image" -or $Args[1] -ne "export") {
    [Console]::Error.WriteLine("fake-regctl only supports: image export IMAGE")
    exit 2
}

$tarPath = $env:TINYLOADER_FAKE_EXPORT_TAR
if ([string]::IsNullOrWhiteSpace($tarPath) -or -not (Test-Path -LiteralPath $tarPath -PathType Leaf)) {
    [Console]::Error.WriteLine("TINYLOADER_FAKE_EXPORT_TAR is not set or does not point to a file.")
    exit 3
}

$inputStream = [System.IO.File]::OpenRead($tarPath)
$outputStream = [Console]::OpenStandardOutput()
$buffer = New-Object byte[] 65536
try {
    while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $outputStream.Write($buffer, 0, $read)
    }
    $outputStream.Flush()
}
finally {
    $inputStream.Dispose()
}
'@

    [System.IO.File]::WriteAllText($fakePs1, $script, (New-Utf8NoBomEncoding))
    return $fakeCmd
}

# 子 PowerShell で download.ps1 を起動するため、現在実行中の pwsh/powershell を使う。
function Get-CurrentPowerShellPath {
    $processPath = (Get-Process -Id $PID).Path
    Assert-True -Condition (Test-Path -LiteralPath $processPath -PathType Leaf) -Message "Could not resolve current PowerShell executable."
    return $processPath
}

function Invoke-DownloadScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImageRef,

        [Parameter(Mandatory = $true)]
        [string]$RegctlPath,

        [Parameter(Mandatory = $true)]
        [double]$DownloadPartSizeGB,

        [switch]$SkipValidation
    )

    $ps = Get-CurrentPowerShellPath
    $partSizeText = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0}", $DownloadPartSizeGB)

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $DownloadScript,
        "-ImageRef", $ImageRef,
        "-PartSizeGB", $partSizeText,
        "-RegctlPath", $RegctlPath,
        # 巨大イメージの検証ではログが肥大化しないよう、通常運用と同じ間隔に寄せる。
        "-ProgressIntervalMB", "256"
    )

    if ($SkipValidation) {
        $args += "-SkipOciValidation"
    }

    & $ps @args
    if ($LASTEXITCODE -ne 0) {
        throw "download.ps1 failed with exit code $LASTEXITCODE"
    }
}

function Read-TestDownloadState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImageOutputDir
    )

    $statePath = Join-Path $ImageOutputDir ".download-state.json"
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $null
    }

    return (Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json)
}

# ユーザが Samba ファイルサーバへ手動移動する操作を、テストでは Move-Item で模擬する。
function Invoke-ManualDownloadLoop {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reference,

        [Parameter(Mandatory = $true)]
        [string]$FileBase,

        [Parameter(Mandatory = $true)]
        [string]$RemotePartsDir,

        [Parameter(Mandatory = $true)]
        [string]$RegctlPath,

        [Parameter(Mandatory = $true)]
        [double]$DownloadPartSizeGB,

        [switch]$SkipValidation,

        [int]$MaxRuns = 100
    )

    $downloadScriptDir = Split-Path -Parent $DownloadScript
    $imageOutputDir = Join-Path $downloadScriptDir $FileBase

    for ($run = 1; $run -le $MaxRuns; $run++) {
        Write-Host ("download.ps1 run #{0}" -f $run)
        Invoke-DownloadScript `
            -ImageRef $Reference `
            -RegctlPath $RegctlPath `
            -DownloadPartSizeGB $DownloadPartSizeGB `
            -SkipValidation:$SkipValidation

        $parts = @(Get-PartFilesForBase -Directory $imageOutputDir -FileBase $FileBase)
        foreach ($part in $parts) {
            Move-Item -LiteralPath $part.FullName -Destination $RemotePartsDir -Force
            Write-Host ("Manual move simulated: {0}" -f $part.Name)
        }

        $state = Read-TestDownloadState -ImageOutputDir $imageOutputDir
        if ($null -ne $state -and [bool]$state.Completed -and $parts.Count -eq 0) {
            return
        }
    }

    throw "download.ps1 did not reach completed state within $MaxRuns runs."
}

# Windows パスを WSL から見える /mnt/c/... 形式に変換する。
function Get-WslPath {
    param([Parameter(Mandatory = $true)][string]$WindowsPath)

    $result = (& wsl.exe --exec wslpath -a $WindowsPath)
    if ($LASTEXITCODE -ne 0) {
        throw "wslpath failed for: $WindowsPath"
    }

    return ($result | Select-Object -First 1).Trim()
}

# merge.sh は本番では docker load まで行うが、テストでは --no-load で結合だけ確認する。
function Invoke-WslMerge {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PartsDir,

        [Parameter(Mandatory = $true)]
        [string]$FileBase,

        [Parameter(Mandatory = $true)]
        [string]$OutputTar
    )

    $repoWsl = Get-WslPath -WindowsPath $RepoRoot
    $partsWsl = Get-WslPath -WindowsPath $PartsDir
    $outputWsl = Get-WslPath -WindowsPath $OutputTar

    & wsl.exe --cd $repoWsl --exec chmod +x ./merge.sh
    if ($LASTEXITCODE -ne 0) {
        throw "chmod +x merge.sh failed in WSL"
    }

    & wsl.exe --cd $repoWsl --exec ./merge.sh --no-load --sha256 --force $partsWsl $FileBase $outputWsl
    if ($LASTEXITCODE -ne 0) {
        throw "merge.sh failed with exit code $LASTEXITCODE"
    }
}

# merge 後 tar が tar として読めることを確認する。内容は出さず、構造だけ見ている。
function Assert-WslTarReadable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TarPath
    )

    $tarWsl = Get-WslPath -WindowsPath $TarPath
    & wsl.exe --exec tar -tf $tarWsl | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "merged tar is not readable by WSL tar: $TarPath"
    }
}

# merge.sh の実行に必要な WSL 側コマンドを事前に確認する。
function Assert-WslAvailable {
    $command = Get-Command -Name "wsl.exe" -ErrorAction SilentlyContinue
    Assert-True -Condition ($null -ne $command) -Message "wsl.exe was not found."

    & wsl.exe --exec sh -c "command -v bash >/dev/null && command -v chmod >/dev/null && command -v find >/dev/null && command -v sha256sum >/dev/null && command -v sort >/dev/null && command -v tar >/dev/null"
    if ($LASTEXITCODE -ne 0) {
        throw "WSL does not have the required commands: bash, chmod, find, sha256sum, sort, tar"
    }
}

# 引数なしの高速テスト。外部 registry、Docker、巨大ファイルに依存しない。
function Invoke-SyntheticTest {
    $exportTar = Join-Path $WorkRoot "export.tar"
    $remoteParts = Join-Path $WorkRoot "remote_parts"
    $toolsDir = Join-Path $WorkRoot "tools"
    $mergedTar = Join-Path $WorkRoot "merged.tar"

    New-Item -ItemType Directory -Path $remoteParts, $toolsDir | Out-Null
    New-TestOciTar -TarPath $exportTar
    $fakeRegctl = New-FakeRegctl -Directory $toolsDir

    $env:TINYLOADER_FAKE_EXPORT_TAR = $exportTar
    try {
        $imageRef = "registry.example.com/tinyloader/test-image:v1"
        $fileBase = "tinyloader_test-image_v1"

        Write-Host "Running download.ps1 test..."
        Invoke-ManualDownloadLoop `
            -Reference $imageRef `
            -FileBase $fileBase `
            -RemotePartsDir $remoteParts `
            -RegctlPath $fakeRegctl `
            -DownloadPartSizeGB 0.000001 `
            -MaxRuns 30

        $imageOutputDir = Join-Path (Split-Path -Parent $DownloadScript) $fileBase
        $localPartFiles = @(Get-PartFilesForBase -Directory $imageOutputDir -FileBase $fileBase)
        Assert-True -Condition ($localPartFiles.Count -eq 0) -Message "download.ps1 left local Part files after simulated manual move."

        $remotePartFiles = @(Get-PartFilesForBase -Directory $remoteParts -FileBase $fileBase)
        Assert-True -Condition ($remotePartFiles.Count -gt 2) -Message "download.ps1 did not create multiple remote Part files."

        Write-Host "Running merge.sh test through WSL..."
        Invoke-WslMerge -PartsDir $remoteParts -FileBase $fileBase -OutputTar $mergedTar

        Assert-True -Condition (Test-Path -LiteralPath $mergedTar -PathType Leaf) -Message "merge.sh did not create merged tar."

        $sourceHash = Get-FileSha256Hex -Path $exportTar
        $mergedHash = Get-FileSha256Hex -Path $mergedTar
        Assert-True -Condition ($sourceHash -eq $mergedHash) -Message "merged tar hash does not match original export tar."
        Assert-WslTarReadable -TarPath $mergedTar

        Write-Host "OK: download.ps1 split/copy validation passed."
        Write-Host "OK: merge.sh sort/merge validation passed."
        Write-Host "OK: merged tar sha256 = $mergedHash"
    }
    finally {
        Remove-Item Env:\TINYLOADER_FAKE_EXPORT_TAR -ErrorAction SilentlyContinue
    }
}

# ImageRef 指定時の実イメージテスト。実際に registry から取得し、Part 化と merge を確認する。
function Invoke-ImageRefTest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reference
    )

    $remoteParts = Join-Path $WorkRoot "remote_parts"
    $mergedTar = Join-Path $WorkRoot "merged.tar"
    $resolvedRegctl = Resolve-TestExecutablePath -Path $RegctlPath
    $fileBase = Get-ImageFileBaseForTest -Reference $Reference

    New-Item -ItemType Directory -Path $remoteParts | Out-Null

    Write-Warning "ImageRef 指定モードは実際にイメージを取得し、merge 後の tar も作成します。巨大イメージでは時間とディスク容量を消費します。"
    Write-Host ("Running download.ps1 test for image: {0}" -f $Reference)
    Invoke-ManualDownloadLoop `
        -Reference $Reference `
        -FileBase $fileBase `
        -RemotePartsDir $remoteParts `
        -RegctlPath $resolvedRegctl `
        -DownloadPartSizeGB $PartSizeGB `
        -SkipValidation:$SkipOciValidation `
        -MaxRuns 10000

    $imageOutputDir = Join-Path (Split-Path -Parent $DownloadScript) $fileBase
    $localPartFiles = @(Get-PartFilesForBase -Directory $imageOutputDir -FileBase $fileBase)
    Assert-True -Condition ($localPartFiles.Count -eq 0) -Message "download.ps1 left local Part files after simulated manual move."

    $remotePartFiles = @(Get-PartFilesForBase -Directory $remoteParts -FileBase $fileBase)
    Assert-True -Condition ($remotePartFiles.Count -gt 0) -Message "download.ps1 did not create remote Part files for $fileBase."

    Write-Host "Running merge.sh test through WSL..."
    Invoke-WslMerge -PartsDir $remoteParts -FileBase $fileBase -OutputTar $mergedTar

    Assert-True -Condition (Test-Path -LiteralPath $mergedTar -PathType Leaf) -Message "merge.sh did not create merged tar."

    $partsHash = Get-ConcatenatedFilesSha256Hex -Files $remotePartFiles
    $mergedHash = Get-FileSha256Hex -Path $mergedTar
    Assert-True -Condition ($partsHash -eq $mergedHash) -Message "merged tar hash does not match concatenated Part files."
    Assert-WslTarReadable -TarPath $mergedTar

    Write-Host ("OK: image test passed for {0}" -f $Reference)
    Write-Host ("OK: part count = {0}" -f $remotePartFiles.Count)
    Write-Host ("OK: merged tar sha256 = {0}" -f $mergedHash)
}

$success = $false

try {
    Assert-True -Condition (Test-Path -LiteralPath $DownloadScript -PathType Leaf) -Message "download.ps1 was not found."
    Assert-True -Condition (Test-Path -LiteralPath $MergeScript -PathType Leaf) -Message "merge.sh was not found."
    Assert-WslAvailable

    Remove-TestWorkRoot
    New-Item -ItemType Directory -Path $WorkRoot | Out-Null
    Copy-Item -LiteralPath $DownloadScript -Destination (Join-Path $WorkRoot "download.ps1") -Force
    $script:DownloadScript = Join-Path $WorkRoot "download.ps1"

    if ([string]::IsNullOrWhiteSpace($ImageRef)) {
        Invoke-SyntheticTest
    }
    else {
        Invoke-ImageRefTest -Reference $ImageRef
    }

    $success = $true
}
finally {
    if ($success -and -not $KeepWorkDir) {
        Remove-TestWorkRoot
    }
    elseif (-not $success) {
        Write-Warning "Test work directory was kept for inspection: $WorkRoot"
    }
}
