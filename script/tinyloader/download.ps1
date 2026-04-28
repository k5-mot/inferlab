$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Windows PowerShell 5.1 で古い TLS 既定値に当たる環境を避ける。
try {
  [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
}

function Show-Usage {
  @"
Usage:
  powershell -ExecutionPolicy Bypass -File .\download.ps1 --image-ref IMAGE_REF [options]
  pwsh -File ./download.ps1 --image-ref IMAGE_REF [options]

Options:
  --image-ref IMAGE_REF   OCI registry image reference to download.
  --part-size-gb SIZE     Maximum local blob size budget in GiB before pausing.
                          Default: 20
  --platform PLATFORM     Target platform when the tag points to a manifest list.
                          Default: linux/amd64
  --out-dir PATH          Output root directory. Default: <script-dir>/out
  --debug                 Enable PowerShell trace debug output.
  -h, --help              Show this help.

Exit codes:
  0   Complete.
  20  Paused because the local blob budget was reached.
  1   Error.
"@
}

function Write-Level {
  param(
    [string]$Level,
    [string]$Message,
    [switch]$ErrorStream
  )

  $timestamp = (Get-Date).ToUniversalTime().ToString("HH:mm:ss")
  $line = "[{0}] {1} {2}" -f $timestamp, $Level, $Message
  if ($ErrorStream) {
    [Console]::Error.WriteLine($line)
  } else {
    [Console]::Out.WriteLine($line)
  }
}

function Die {
  param([string]$Message)
  Write-Level -Level "ERROR" -Message $Message -ErrorStream
  exit 1
}

function Log {
  param([string]$Message)
  Write-Level -Level "INFO" -Message $Message
}

function Debug-Log {
  param([string]$Message)
  if ($script:DebugEnabled) {
    Write-Level -Level "DEBUG" -Message $Message -ErrorStream
  }
}

function Warn {
  param([string]$Message)
  Write-Level -Level "WARN" -Message $Message -ErrorStream
}

function Require-Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Die "required command not found: $Name"
  }
}

function Get-ScriptDirectory {
  if ($PSScriptRoot) {
    return $PSScriptRoot
  }
  if ($PSCommandPath) {
    return (Split-Path -Parent $PSCommandPath)
  }
  return (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

function Get-NextArg {
  param(
    [object[]]$Values,
    [int]$Index,
    [string]$OptionName
  )
  if ($Index + 1 -ge $Values.Count) {
    Die "missing value for $OptionName"
  }
  return $Values[$Index + 1]
}

function Parse-Arguments {
  param([object[]]$Values)

  for ($i = 0; $i -lt $Values.Count; $i++) {
    $arg = [string]$Values[$i]
    switch -Regex ($arg) {
      '^--image-ref=(.+)$' {
        $script:ImageRef = $Matches[1]
        continue
      }
      '^--part-size-gb=(.+)$' {
        $script:PartSizeGb = $Matches[1]
        continue
      }
      '^--platform=(.+)$' {
        $script:Platform = $Matches[1]
        continue
      }
      '^--out-dir=(.+)$' {
        $script:OutRoot = $Matches[1]
        continue
      }
      '^(--image-ref|-ImageRef)$' {
        $script:ImageRef = Get-NextArg -Values $Values -Index $i -OptionName $arg
        $i++
        continue
      }
      '^(--part-size-gb|-PartSizeGb)$' {
        $script:PartSizeGb = Get-NextArg -Values $Values -Index $i -OptionName $arg
        $i++
        continue
      }
      '^(--platform|-Platform)$' {
        $script:Platform = Get-NextArg -Values $Values -Index $i -OptionName $arg
        $i++
        continue
      }
      '^(--out-dir|-OutDir)$' {
        $script:OutRoot = Get-NextArg -Values $Values -Index $i -OptionName $arg
        $i++
        continue
      }
      '^(--debug|-Debug)$' {
        $script:DebugEnabled = $true
        continue
      }
      '^(-h|--help|/help|\?)$' {
        Show-Usage
        exit 0
      }
      default {
        Die "unknown option: $arg"
      }
    }
  }
}

function ConvertTo-SafeName {
  param([string]$Value)
  return (($Value -replace '[/:@]', '_') -replace '[^A-Za-z0-9._-]', '_')
}

function Get-DigestHex {
  param([string]$Digest)
  if ($Digest -notmatch ':') {
    return $Digest
  }
  return ($Digest -replace '^[^:]*:', '')
}

function Get-FileSize {
  param([string]$Path)
  return [int64](Get-Item -LiteralPath $Path).Length
}

function Convert-BytesToHuman {
  param([int64]$Bytes)

  $units = @("B", "KiB", "MiB", "GiB", "TiB")
  [double]$value = $Bytes
  $unitIndex = 0
  while ($value -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
    $value = $value / 1024
    $unitIndex++
  }
  return ("{0:N2} {1}" -f $value, $units[$unitIndex])
}

function Convert-GibToBytes {
  param([string]$SizeGb)

  try {
    [decimal]$size = [decimal]::Parse(
      $SizeGb,
      [Globalization.NumberStyles]::Float,
      [Globalization.CultureInfo]::InvariantCulture
    )
  } catch {
    Die "--part-size-gb must be a positive number"
  }

  if ($size -le 0) {
    Die "--part-size-gb must be a positive number"
  }

  return [int64][Math]::Round($size * 1024 * 1024 * 1024, 0)
}

function Encode-UrlComponent {
  param([string]$Value)
  return [System.Uri]::EscapeDataString($Value)
}

function Get-UtcTimestamp {
  return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Parse-Platform {
  param([string]$Raw)

  $parts = $Raw -split '/'
  if ($parts.Count -lt 2 -or $parts.Count -gt 3 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
    Die "platform must look like os/arch or os/arch/variant: $Raw"
  }

  $script:PlatformOs = $parts[0]
  $script:PlatformArch = $parts[1]
  if ($parts.Count -eq 3) {
    $script:PlatformVariant = $parts[2]
  } else {
    $script:PlatformVariant = ""
  }
}

function Parse-ImageRef {
  param([string]$Raw)

  $first = ($Raw -split '/', 2)[0]
  if ($Raw.Contains('/') -and ($first -like '*.*' -or $first -like '*:*' -or $first -eq "localhost")) {
    $script:Registry = $first
    $path = $Raw.Substring($first.Length + 1)
  } else {
    $script:Registry = "docker.io"
    $path = $Raw
  }

  if ($path.Contains('@')) {
    $at = $path.LastIndexOf('@')
    $script:Reference = $path.Substring($at + 1)
    $script:Repository = $path.Substring(0, $at)
    $script:ReferenceKind = "digest"
  } else {
    $lastSlash = $path.LastIndexOf('/')
    $last = $path
    if ($lastSlash -ge 0) {
      $last = $path.Substring($lastSlash + 1)
    }

    if ($last.Contains(':')) {
      $colon = $path.LastIndexOf(':')
      $script:Reference = $path.Substring($colon + 1)
      $script:Repository = $path.Substring(0, $colon)
    } else {
      $script:Reference = "latest"
      $script:Repository = $path
    }
    $script:ReferenceKind = "tag"
  }

  if ([string]::IsNullOrWhiteSpace($script:Repository)) {
    Die "could not parse repository from image ref: $Raw"
  }

  if ($script:Registry -eq "docker.io" -and -not $script:Repository.Contains('/')) {
    $script:Repository = "library/$($script:Repository)"
  }

  if ($script:ReferenceKind -eq "digest") {
    $script:CanonicalImageRef = "{0}/{1}@{2}" -f $script:Registry, $script:Repository, $script:Reference
  } else {
    $script:CanonicalImageRef = "{0}/{1}:{2}" -f $script:Registry, $script:Repository, $script:Reference
  }

  if ($script:Registry -eq "docker.io") {
    $script:RegistryApiHost = "registry-1.docker.io"
  } else {
    $script:RegistryApiHost = $script:Registry
  }
}

function Get-HeaderValue {
  param(
    [object]$Headers,
    [string]$Name
  )

  if ($null -eq $Headers) {
    return ""
  }

  if ($Headers -is [System.Net.WebHeaderCollection]) {
    $value = $Headers.Get($Name)
    if ($null -eq $value) {
      return ""
    }
    return [string]$value
  }

  foreach ($key in $Headers.Keys) {
    if ([string]::Equals([string]$key, $Name, [StringComparison]::OrdinalIgnoreCase)) {
      $value = $Headers[$key]
      if ($value -is [array]) {
        return ($value -join ", ")
      }
      return [string]$value
    }
  }

  return ""
}

function Get-AuthParam {
  param(
    [string]$Challenge,
    [string]$Key
  )

  $pattern = '(?i)(?:^|[,\s])' + [Regex]::Escape($Key) + '="([^"]*)"'
  $match = [Regex]::Match($Challenge, $pattern)
  if ($match.Success) {
    return $match.Groups[1].Value
  }
  return ""
}

function Read-ErrorBodyToFile {
  param(
    [object]$Response,
    [string]$OutputPath
  )

  try {
    if ($Response.GetType().FullName -eq "System.Net.Http.HttpResponseMessage") {
      $bytes = $Response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
      [IO.File]::WriteAllBytes($OutputPath, $bytes)
      return
    }

    if ($Response -is [System.Net.HttpWebResponse]) {
      $stream = $Response.GetResponseStream()
      if ($null -eq $stream) {
        return
      }

      $file = [IO.File]::Open($OutputPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
      try {
        $stream.CopyTo($file)
      } finally {
        $file.Dispose()
        $stream.Dispose()
      }
    }
  } catch {
  }
}

function Merge-HttpResponseHeaders {
  param([object]$Response)

  $headers = @{}
  foreach ($header in $Response.Headers.GetEnumerator()) {
    $headers[$header.Key] = ($header.Value -join ", ")
  }
  if ($null -ne $Response.Content) {
    foreach ($header in $Response.Content.Headers.GetEnumerator()) {
      $headers[$header.Key] = ($header.Value -join ", ")
    }
  }
  return $headers
}

function Invoke-WebGetToFile {
  param(
    [string]$Url,
    [hashtable]$Headers,
    [string]$OutputPath
  )

  $parameters = @{
    Uri = $Url
    OutFile = $OutputPath
    Headers = $Headers
    Method = "Get"
    MaximumRedirection = 10
    ErrorAction = "Stop"
  }

  if ($PSVersionTable.PSVersion.Major -lt 6) {
    $parameters["UseBasicParsing"] = $true
  }

  try {
    $response = Invoke-WebRequest @parameters
    return @{
      Code = [int]$response.StatusCode
      Headers = $response.Headers
    }
  } catch {
    $response = $_.Exception.Response
    if ($null -eq $response) {
      throw
    }

    Read-ErrorBodyToFile -Response $response -OutputPath $OutputPath

    if ($response.GetType().FullName -eq "System.Net.Http.HttpResponseMessage") {
      return @{
        Code = [int]$response.StatusCode
        Headers = (Merge-HttpResponseHeaders -Response $response)
      }
    }

    if ($response -is [System.Net.HttpWebResponse]) {
      return @{
        Code = [int]$response.StatusCode
        Headers = $response.Headers
      }
    }

    throw
  }
}

function Fetch-BearerToken {
  param([string]$Challenge)

  if ($Challenge -notmatch '^[Bb]earer\b') {
    Die "unsupported registry authentication challenge: $Challenge"
  }

  $realm = Get-AuthParam -Challenge $Challenge -Key "realm"
  $service = Get-AuthParam -Challenge $Challenge -Key "service"
  $scope = Get-AuthParam -Challenge $Challenge -Key "scope"

  if ([string]::IsNullOrWhiteSpace($realm)) {
    Die "authentication realm was not present in challenge"
  }
  if ([string]::IsNullOrWhiteSpace($scope)) {
    $scope = "repository:$($script:Repository):pull"
  }

  $separator = "?"
  if ($realm.Contains('?')) {
    $separator = "&"
  }

  $tokenUrl = $realm + $separator
  if (-not [string]::IsNullOrWhiteSpace($service)) {
    $tokenUrl += "service=$(Encode-UrlComponent $service)&"
  }
  $tokenUrl += "scope=$(Encode-UrlComponent $scope)"

  try {
    $response = Invoke-RestMethod -Uri $tokenUrl -Method Get -ErrorAction Stop
  } catch {
    Die "failed to acquire bearer token from: $realm"
  }

  $token = ""
  if ($response.PSObject.Properties.Name -contains "token") {
    $token = [string]$response.token
  }
  if ([string]::IsNullOrWhiteSpace($token) -and $response.PSObject.Properties.Name -contains "access_token") {
    $token = [string]$response.access_token
  }
  if ([string]::IsNullOrWhiteSpace($token)) {
    Die "registry token response did not include a token"
  }

  $script:RegistryAuthHeader = "Bearer $token"
}

function Invoke-RegistryGet {
  param(
    [string]$Url,
    [string]$AcceptHeader,
    [string]$OutputPath
  )

  $headers = @{}
  if (-not [string]::IsNullOrWhiteSpace($AcceptHeader)) {
    $headers["Accept"] = $AcceptHeader
  }
  if (-not [string]::IsNullOrWhiteSpace($script:RegistryAuthHeader)) {
    $headers["Authorization"] = $script:RegistryAuthHeader
  }

  try {
    $result = Invoke-WebGetToFile -Url $Url -Headers $headers -OutputPath $OutputPath
  } catch {
    Die "web request failed for: $Url"
  }

  if ($result.Code -eq 401) {
    $challenge = Get-HeaderValue -Headers $result.Headers -Name "www-authenticate"
    if ([string]::IsNullOrWhiteSpace($challenge)) {
      Die "registry returned 401 without WWW-Authenticate header"
    }

    Fetch-BearerToken -Challenge $challenge

    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($AcceptHeader)) {
      $headers["Accept"] = $AcceptHeader
    }
    $headers["Authorization"] = $script:RegistryAuthHeader

    try {
      $result = Invoke-WebGetToFile -Url $Url -Headers $headers -OutputPath $OutputPath
    } catch {
      Die "web request failed for: $Url"
    }
  }

  $script:LastResponseHeaders = $result.Headers
  $script:LastResponseCode = [string]$result.Code

  if ($script:LastResponseCode -notmatch '^2') {
    $message = ""
    if (Test-Path -LiteralPath $OutputPath) {
      try {
        $stream = [IO.File]::OpenRead($OutputPath)
        try {
          $count = [Math]::Min(400, [int]$stream.Length)
          $buffer = New-Object byte[] $count
          [void]$stream.Read($buffer, 0, $count)
          $message = [Text.Encoding]::UTF8.GetString($buffer) -replace "`r?`n", " "
        } finally {
          $stream.Dispose()
        }
      } catch {
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($message)) {
      Die "registry request failed with HTTP $($script:LastResponseCode): $Url :: $message"
    }
    Die "registry request failed with HTTP $($script:LastResponseCode): $Url"
  }
}

function Get-Sha256Hex {
  param([string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-JsonFile {
  param([string]$Path)
  return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Write-JsonFile {
  param(
    [object]$Value,
    [string]$Path
  )

  $tmpPath = [IO.Path]::GetTempFileName()
  try {
    $Value | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $tmpPath -Encoding UTF8
    Move-Item -LiteralPath $tmpPath -Destination $Path -Force
  } catch {
    Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
    throw
  }
}

function Get-JsonPropertyValue {
  param(
    [object]$Object,
    [string]$Name
  )

  if ($null -eq $Object) {
    return $null
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }
  return $property.Value
}

function Fetch-ManifestByRef {
  param(
    [string]$Ref,
    [string]$TargetPath
  )

  $acceptHeader = "application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
  Invoke-RegistryGet -Url "https://$($script:RegistryApiHost)/v2/$($script:Repository)/manifests/$Ref" -AcceptHeader $acceptHeader -OutputPath $TargetPath

  $contentType = Get-HeaderValue -Headers $script:LastResponseHeaders -Name "content-type"
  if ($contentType.Contains(';')) {
    $contentType = ($contentType -split ';', 2)[0]
  }

  $script:RequestedManifestDigest = Get-HeaderValue -Headers $script:LastResponseHeaders -Name "docker-content-digest"
  $script:RequestedManifestMediaType = $contentType

  if ([string]::IsNullOrWhiteSpace($script:RequestedManifestDigest)) {
    $script:RequestedManifestDigest = "sha256:$(Get-Sha256Hex -Path $TargetPath)"
  }
  if ([string]::IsNullOrWhiteSpace($script:RequestedManifestMediaType)) {
    $manifest = Read-JsonFile -Path $TargetPath
    $script:RequestedManifestMediaType = [string](Get-JsonPropertyValue -Object $manifest -Name "mediaType")
  }
}

function Resolve-Manifest {
  $requestBody = [IO.Path]::GetTempFileName()

  try {
    Fetch-ManifestByRef -Ref $script:Reference -TargetPath $requestBody
    $requestJson = Read-JsonFile -Path $requestBody
    $manifestKind = [string](Get-JsonPropertyValue -Object $requestJson -Name "mediaType")
    if ([string]::IsNullOrWhiteSpace($manifestKind)) {
      $manifestKind = $script:RequestedManifestMediaType
    }

    switch ($manifestKind) {
      "application/vnd.oci.image.index.v1+json" {
        Resolve-ManifestList -RequestBody $requestBody -RequestJson $requestJson
        return
      }
      "application/vnd.docker.distribution.manifest.list.v2+json" {
        Resolve-ManifestList -RequestBody $requestBody -RequestJson $requestJson
        return
      }
      "application/vnd.oci.image.manifest.v1+json" {
        $script:SelectedManifestDigest = $script:RequestedManifestDigest
        $script:SelectedManifestMediaType = $script:RequestedManifestMediaType
        $script:SelectedManifestSize = Get-FileSize -Path $requestBody
        Move-Item -LiteralPath $requestBody -Destination $script:ManifestFile -Force
        return
      }
      "application/vnd.docker.distribution.manifest.v2+json" {
        $script:SelectedManifestDigest = $script:RequestedManifestDigest
        $script:SelectedManifestMediaType = $script:RequestedManifestMediaType
        $script:SelectedManifestSize = Get-FileSize -Path $requestBody
        Move-Item -LiteralPath $requestBody -Destination $script:ManifestFile -Force
        return
      }
      default {
        Die "unsupported manifest media type: $manifestKind"
      }
    }
  } finally {
    Remove-Item -LiteralPath $requestBody -Force -ErrorAction SilentlyContinue
  }
}

function Resolve-ManifestList {
  param(
    [string]$RequestBody,
    [object]$RequestJson
  )

  $selected = @($RequestJson.manifests) | Where-Object {
    $platform = $_.platform
    $variant = ""
    if ($null -ne $platform -and $platform.PSObject.Properties.Name -contains "variant") {
      $variant = [string]$platform.variant
    }
    $matchesOs = ($null -ne $platform -and [string]$platform.os -eq $script:PlatformOs)
    $matchesArch = ($null -ne $platform -and [string]$platform.architecture -eq $script:PlatformArch)
    $matchesVariant = ([string]::IsNullOrEmpty($script:PlatformVariant) -or $variant -eq $script:PlatformVariant)
    $matchesOs -and $matchesArch -and $matchesVariant
  } | Select-Object -First 1

  if ($null -eq $selected) {
    Die "platform $($script:Platform) was not found in manifest list"
  }

  $resolvedBody = [IO.Path]::GetTempFileName()
  try {
    Fetch-ManifestByRef -Ref ([string]$selected.digest) -TargetPath $resolvedBody
    $script:SelectedManifestDigest = $script:RequestedManifestDigest
    $script:SelectedManifestMediaType = $script:RequestedManifestMediaType
    $script:SelectedManifestSize = Get-FileSize -Path $resolvedBody
    Move-Item -LiteralPath $resolvedBody -Destination $script:ManifestFile -Force
  } finally {
    Remove-Item -LiteralPath $resolvedBody -Force -ErrorAction SilentlyContinue
  }
}

function Write-State {
  $now = Get-UtcTimestamp
  $manifest = Read-JsonFile -Path $script:ManifestFile
  $blobs = New-Object System.Collections.ArrayList

  [void]$blobs.Add([ordered]@{
    role = "config"
    digest = [string]$manifest.config.digest
    size = [int64]$manifest.config.size
    downloaded = $false
  })

  foreach ($layer in @($manifest.layers)) {
    [void]$blobs.Add([ordered]@{
      role = "layer"
      digest = [string]$layer.digest
      size = [int64]$layer.size
      downloaded = $false
    })
  }

  $state = [ordered]@{
    schema = 1
    image_ref = $script:CanonicalImageRef
    registry = $script:Registry
    repository = $script:Repository
    reference = $script:Reference
    reference_kind = $script:ReferenceKind
    platform = $script:Platform
    manifest = [ordered]@{
      digest = $script:SelectedManifestDigest
      media_type = $script:SelectedManifestMediaType
      size = [int64]$script:SelectedManifestSize
    }
    blobs = $blobs.ToArray()
    complete = $false
    created_at = $now
    updated_at = $now
  }

  Write-JsonFile -Value $state -Path $script:StateFile
}

function Set-BlobDownloaded {
  param([string]$Digest)

  $state = Read-JsonFile -Path $script:StateFile
  foreach ($blob in @($state.blobs)) {
    if ([string]$blob.digest -eq $Digest) {
      $blob.downloaded = $true
    }
  }

  $remaining = @($state.blobs | Where-Object { -not ([bool]$_.downloaded) }).Count
  $state.complete = ($remaining -eq 0)
  $state.updated_at = Get-UtcTimestamp
  Write-JsonFile -Value $state -Path $script:StateFile
}

function Refresh-ManifestAndState {
  if (Test-Path -LiteralPath $script:StateFile) {
    $state = Read-JsonFile -Path $script:StateFile
    $existingRef = [string](Get-JsonPropertyValue -Object $state -Name "image_ref")
    $existingPlatform = [string](Get-JsonPropertyValue -Object $state -Name "platform")

    if ($existingRef -ne $script:CanonicalImageRef) {
      Die "state.json belongs to another image: $existingRef"
    }
    if (-not [string]::IsNullOrWhiteSpace($existingPlatform) -and $existingPlatform -ne $script:Platform) {
      Die "state.json belongs to another platform: $existingPlatform"
    }
  }

  if (-not (Test-Path -LiteralPath $script:StateFile) -or -not (Test-Path -LiteralPath $script:ManifestFile)) {
    Log "Resolving manifest for $($script:CanonicalImageRef) ($($script:Platform))"
    Resolve-Manifest
    Write-State
    return
  }

  $state = Read-JsonFile -Path $script:StateFile
  $script:SelectedManifestDigest = [string]$state.manifest.digest
  $script:SelectedManifestMediaType = [string]$state.manifest.media_type
  $script:SelectedManifestSize = [int64]$state.manifest.size
}

function Get-LocalBlobBytes {
  if (-not (Test-Path -LiteralPath $script:BlobsDir)) {
    return [int64]0
  }

  [int64]$total = 0
  Get-ChildItem -LiteralPath $script:BlobsDir -File -ErrorAction SilentlyContinue | ForEach-Object {
    $total += [int64]$_.Length
  }
  return $total
}

function Mark-ExistingBlobs {
  $state = Read-JsonFile -Path $script:StateFile
  foreach ($blob in @($state.blobs)) {
    $digest = [string]$blob.digest
    $expectedSize = [int64]$blob.size
    $downloaded = [bool]$blob.downloaded
    $blobPath = Join-Path $script:BlobsDir (Get-DigestHex -Digest $digest)

    if (Test-Path -LiteralPath $blobPath) {
      $actualSize = Get-FileSize -Path $blobPath
      if ($actualSize -eq $expectedSize) {
        if (-not $downloaded) {
          Set-BlobDownloaded -Digest $digest
        }
      } else {
        Warn "removing partial blob with unexpected size: $blobPath"
        Remove-Item -LiteralPath $blobPath -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

function Pause-ForQuota {
  param(
    [int64]$CurrentBytes,
    [string]$NextDigest = "",
    [int64]$NextSize = 0
  )

  [Console]::Error.WriteLine("")
  [Console]::Error.WriteLine("ALERT: local blob usage reached the configured limit.")
  [Console]::Error.WriteLine("  current: $(Convert-BytesToHuman -Bytes $CurrentBytes)")
  [Console]::Error.WriteLine("  limit:   $(Convert-BytesToHuman -Bytes $script:PartSizeBytes)")
  if (-not [string]::IsNullOrWhiteSpace($NextDigest)) {
    [Console]::Error.WriteLine("  next:    $NextDigest ($(Convert-BytesToHuman -Bytes $NextSize))")
  }
  [Console]::Error.WriteLine("")
  [Console]::Error.WriteLine("Move the files under $($script:BlobsDir) to your temporary storage, keep state.json and manifest.json in place, then rerun the same command.")
  exit 20
}

function Download-Blob {
  param(
    [string]$Digest,
    [int64]$ExpectedSize,
    [string]$Role
  )

  $blobPath = Join-Path $script:BlobsDir (Get-DigestHex -Digest $Digest)
  $tmpPath = "$blobPath.partial.$PID"

  Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue

  Log "Downloading $Role $Digest ($(Convert-BytesToHuman -Bytes $ExpectedSize))"
  Invoke-RegistryGet -Url "https://$($script:RegistryApiHost)/v2/$($script:Repository)/blobs/$Digest" -AcceptHeader "" -OutputPath $tmpPath
  $script:LastResponseHeaders = $null

  $actualSize = Get-FileSize -Path $tmpPath
  if ($actualSize -ne $ExpectedSize) {
    Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
    Die "downloaded blob size does not match manifest metadata: $Digest (expected $ExpectedSize, got $actualSize)"
  }

  $actualDigest = Get-Sha256Hex -Path $tmpPath
  if ($actualDigest -ne (Get-DigestHex -Digest $Digest)) {
    Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
    Die "downloaded blob digest does not match: $Digest"
  }

  Move-Item -LiteralPath $tmpPath -Destination $blobPath -Force
}

$script:ScriptDir = Get-ScriptDirectory
$script:OutRoot = Join-Path $script:ScriptDir "out"
$script:ImageRef = ""
$script:PartSizeGb = "20"
$script:Platform = "linux/amd64"
$script:DebugEnabled = $false
$script:RegistryAuthHeader = ""
$script:LastResponseHeaders = $null
$script:LastResponseCode = ""
$script:RequestedManifestDigest = ""
$script:RequestedManifestMediaType = ""
$script:SelectedManifestDigest = ""
$script:SelectedManifestMediaType = ""
$script:SelectedManifestSize = 0

Parse-Arguments -Values $args

if ([string]::IsNullOrWhiteSpace($script:ImageRef)) {
  Show-Usage | ForEach-Object { [Console]::Error.WriteLine($_) }
  exit 2
}

if ($script:DebugEnabled) {
  Debug-Log "PowerShell trace enabled"
  Set-PSDebug -Trace 1
}

Require-Command "Invoke-WebRequest"
Require-Command "Invoke-RestMethod"
Require-Command "Get-FileHash"

Parse-Platform -Raw $script:Platform
Parse-ImageRef -Raw $script:ImageRef
$script:PartSizeBytes = Convert-GibToBytes -SizeGb $script:PartSizeGb

$imageKey = ConvertTo-SafeName -Value $script:CanonicalImageRef
$script:ImageDir = Join-Path $script:OutRoot $imageKey
$script:StateFile = Join-Path $script:ImageDir "state.json"
$script:ManifestFile = Join-Path $script:ImageDir "manifest.json"
$script:BlobsDir = Join-Path (Join-Path $script:ImageDir "blobs") "sha256"

New-Item -ItemType Directory -Path $script:BlobsDir -Force | Out-Null
Refresh-ManifestAndState
Mark-ExistingBlobs

$state = Read-JsonFile -Path $script:StateFile
if ([bool]$state.complete) {
  Log "Complete"
  exit 0
}

$currentBytes = Get-LocalBlobBytes
Log "Local blob usage: $(Convert-BytesToHuman -Bytes $currentBytes) / $(Convert-BytesToHuman -Bytes $script:PartSizeBytes)"

foreach ($blob in @($state.blobs)) {
  $digest = [string]$blob.digest
  $size = [int64]$blob.size
  $role = [string]$blob.role
  $downloaded = [bool]$blob.downloaded

  if ($downloaded) {
    continue
  }

  if ($currentBytes -gt 0 -and ($currentBytes + $size) -gt $script:PartSizeBytes) {
    Pause-ForQuota -CurrentBytes $currentBytes -NextDigest $digest -NextSize $size
  }

  if ($currentBytes -eq 0 -and $size -gt $script:PartSizeBytes) {
    Die "blob $digest ($(Convert-BytesToHuman -Bytes $size)) exceeds the configured limit ($(Convert-BytesToHuman -Bytes $script:PartSizeBytes)). Increase --part-size-gb."
  }

  Download-Blob -Digest $digest -ExpectedSize $size -Role $role
  Set-BlobDownloaded -Digest $digest
  $currentBytes += $size

  $state = Read-JsonFile -Path $script:StateFile
  $doneCount = @($state.blobs | Where-Object { [bool]$_.downloaded }).Count
  $totalCount = @($state.blobs).Count
  Log "Downloaded $doneCount/$totalCount blobs"

  if ([bool]$state.complete) {
    Log "Complete"
    exit 0
  }

  if ($currentBytes -ge $script:PartSizeBytes) {
    Pause-ForQuota -CurrentBytes $currentBytes
  }
}

$state = Read-JsonFile -Path $script:StateFile
if ([bool]$state.complete) {
  Log "Complete"
  exit 0
}

Die "download finished unexpectedly without completing state.json"
