<#
.SYNOPSIS
対象project directoryのPython依存からPyPI wheelhouseを作成します。

.DESCRIPTION
`pyproject.toml`がある場合は`uv export`で`requirements.txt`を生成し、無い場合は既存の`requirements.txt`を使用します。
Python 3.10から3.14のany、Windows、Linux向けwheelを取得し、pypiserverへ配置できるwheelhouseを作成します。

.PARAMETER OutputDir
取得したwheelを保存するdirectoryです。

.PARAMETER ProjectDirectory
依存定義fileがあるproject directoryです。省略時はカレントディレクトリです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\Download-Pip-Packages.ps1 -OutputDir C:\assets\12-registry\pypi

カレントディレクトリのPython依存からregistry投入用wheelhouseを作成します。

.EXAMPLE
.\Download-Pip-Packages.ps1 -ProjectDirectory C:\src\private-chat\api -OutputDir C:\assets\12-registry\pypi

指定したproject directoryのPython依存からregistry投入用wheelhouseを作成します。

.NOTES
副作用として`pyproject.toml`がある場合に`requirements.txt`を生成し、指定directoryへwheelを作成または上書きします。
#>
[CmdletBinding()]
param (
    [string]$OutputDir,

    [string]$ProjectDirectory = (Get-Location).Path,

    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}

$ErrorActionPreference = "Stop"
$PythonVersions = @("3.10", "3.11", "3.12", "3.13", "3.14")
$PytorchCpuIndexUrl = "https://download.pytorch.org/whl/cpu"
$PlatformTargets = @(
    [pscustomobject]@{ Group = "any"; Platform = "any"; Implementation = "py"; Abis = @("none") },
    [pscustomobject]@{ Group = "windows"; Platform = "win32"; Implementation = "cp"; Abis = @() },
    [pscustomobject]@{ Group = "windows"; Platform = "win_amd64"; Implementation = "cp"; Abis = @() },
    [pscustomobject]@{ Group = "linux"; Platform = "manylinux_2_17_x86_64"; Implementation = "cp"; Abis = @() },
    [pscustomobject]@{ Group = "linux"; Platform = "manylinux_2_28_x86_64"; Implementation = "cp"; Abis = @() },
    [pscustomobject]@{ Group = "linux"; Platform = "manylinux2014_x86_64"; Implementation = "cp"; Abis = @() },
    [pscustomobject]@{ Group = "linux"; Platform = "manylinux1_x86_64"; Implementation = "cp"; Abis = @() }
)

if (-not $OutputDir) {
    throw "OutputDir is required."
}

<#
.SYNOPSIS
外部commandを実行し、終了codeを検証します。
.PARAMETER FilePath
実行するcommand名またはpathです。
.PARAMETER Arguments
commandへ渡すargument配列です。
.OUTPUTS
commandの標準出力を返します。
#>
function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    if (-not (Get-Command $FilePath -ErrorAction SilentlyContinue)) {
        throw "required command was not found: $FilePath"
    }

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}

<#
.SYNOPSIS
利用可能なPython 3 commandを検出します。
.OUTPUTS
FilePathとArgumentsを持つcommand情報を返します。
#>
function Get-PythonCommand {
    $Candidates = @()
    if ($env:PYTHON_COMMAND) {
        $Candidates += [pscustomobject]@{ FilePath = $env:PYTHON_COMMAND; Arguments = @() }
    }
    $Candidates += [pscustomobject]@{ FilePath = "python"; Arguments = @() }
    $Candidates += [pscustomobject]@{ FilePath = "py"; Arguments = @("-3") }
    $Candidates += [pscustomobject]@{ FilePath = "python3"; Arguments = @() }

    foreach ($Candidate in $Candidates) {
        if (-not (Get-Command $Candidate.FilePath -ErrorAction SilentlyContinue)) {
            continue
        }

        & $Candidate.FilePath @(@($Candidate.Arguments) + @("--version")) *> $null
        if ($LASTEXITCODE -eq 0) {
            return $Candidate
        }
    }

    throw "required command was not found: Python 3. Install Python 3, enable the py launcher, or set PYTHON_COMMAND."
}

<#
.SYNOPSIS
対象project directoryの依存定義からrequirements.txtを用意します。
.OUTPUTS
requirements.txtの絶対pathを返します。
#>
function Resolve-RequirementsPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDirectory
    )

    $RequirementsPath = Join-Path $ProjectDirectory "requirements.txt"
    $PyprojectPath = Join-Path $ProjectDirectory "pyproject.toml"
    if (Test-Path -Path $PyprojectPath -PathType Leaf) {
        $Arguments = @(
            "export",
            "--project", $ProjectDirectory,
            "--format", "requirements-txt",
            "--no-dev",
            "--no-emit-project",
            "--no-hashes",
            "--output-file", $RequirementsPath
        )
        if (Test-Path -Path (Join-Path $ProjectDirectory "uv.lock") -PathType Leaf) {
            $Arguments += "--locked"
        }
        Invoke-NativeCommand -FilePath "uv" -Arguments $Arguments
    }

    if (-not (Test-Path -Path $RequirementsPath -PathType Leaf)) {
        throw "requirements.txt was not found in project directory: $ProjectDirectory"
    }

    return $RequirementsPath
}

<#
.SYNOPSIS
requirements.txtからdownload対象のrequirement行を取得します。
.PARAMETER Path
requirements.txtのpathです。
.OUTPUTS
pipへ渡すrequirement spec配列を返します。
#>
function Get-RequirementSpecs {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Specs = @()
    foreach ($Line in (Get-Content -Path $Path)) {
        $Trimmed = $Line.Trim()
        if (-not $Trimmed -or $Trimmed.StartsWith("#")) {
            continue
        }
        if ($Trimmed.StartsWith("-")) {
            throw "requirements option is not supported in generated wheelhouse input: $Trimmed"
        }
        $Specs += $Trimmed
    }

    return $Specs
}

<#
.SYNOPSIS
requirementにPyTorch CPU indexが必要か判定します。
.PARAMETER Requirement
判定するrequirement specです。
.OUTPUTS
PyTorch系packageならtrueを返します。
#>
function Test-PytorchRequirement {
    param(
        [Parameter(Mandatory = $true)][string]$Requirement
    )

    return $Requirement -match "^(torch|torchvision|torchaudio)(\b|\[|[<>=!~])"
}

<#
.SYNOPSIS
pinned requirementからpackage名とversionを取得します。
.PARAMETER Requirement
解析するrequirement specです。
.OUTPUTS
NameとVersionを持つobjectを返します。pinned requirementでない場合はnullを返します。
#>
function Get-PinnedRequirementParts {
    param(
        [Parameter(Mandatory = $true)][string]$Requirement
    )

    if ($Requirement -notmatch "^\s*([A-Za-z0-9_.-]+)(?:\[.*\])?==([^;\s]+)") {
        return $null
    }

    return [pscustomobject]@{ Name = $Matches[1]; Version = $Matches[2] }
}

<#
.SYNOPSIS
Requires-Pythonが対象Python versionに一致するか判定します。
.PARAMETER PythonCommand
Python command情報です。
.PARAMETER RequiresPython
PyPI metadataのRequires-Python specです。
.PARAMETER PythonVersion
判定対象Python versionです。
.OUTPUTS
対象Python versionをsupportする場合はtrueを返します。
#>
function Test-PythonVersionRequirement {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$PythonCommand,
        [string]$RequiresPython,
        [Parameter(Mandatory = $true)][string]$PythonVersion
    )

    if (-not $RequiresPython) {
        return $true
    }

    $Code = "from pip._vendor.packaging.specifiers import SpecifierSet; from pip._vendor.packaging.version import Version; import sys; sys.exit(0 if SpecifierSet(sys.argv[1]).contains(Version(sys.argv[2]), prereleases=True) else 1)"
    & $PythonCommand.FilePath @(@($PythonCommand.Arguments) + @("-c", $Code, $RequiresPython, $PythonVersion)) *> $null
    return $LASTEXITCODE -eq 0
}

<#
.SYNOPSIS
pip downloadへ渡すtarget optionを作成します。
.PARAMETER Target
取得対象platform情報です。
.PARAMETER PythonVersion
取得対象Python versionです。
.OUTPUTS
pip downloadへ渡すargument配列を返します。
#>
function Get-PipTargetArguments {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Target,
        [Parameter(Mandatory = $true)][string]$PythonVersion
    )

    $VersionTag = $PythonVersion.Replace(".", "")
    $Abis = if ($Target.Abis.Count -gt 0) {
        $Target.Abis
    } else {
        @("cp$VersionTag", "abi3", "none")
    }

    $Arguments = @("--platform", $Target.Platform)
    foreach ($Abi in $Abis) {
        $Arguments += @("--abi", $Abi)
    }

    return $Arguments + @(
        "--python-version", $PythonVersion,
        "--implementation", $Target.Implementation,
        "--only-binary=:all:"
    )
}

<#
.SYNOPSIS
1つのrequirementを指定target向けに取得します。
.PARAMETER PythonCommand
Python command情報です。
.PARAMETER Requirement
取得するrequirement specです。
.PARAMETER PythonVersion
取得対象Python versionです。
.PARAMETER Target
取得対象platform情報です。
.PARAMETER OutputDir
保存先directoryです。
.OUTPUTS
成功した場合はtrue、取得できない場合はfalseを返します。
#>
function Save-RequirementForTarget {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$PythonCommand,
        [Parameter(Mandatory = $true)][string]$Requirement,
        [Parameter(Mandatory = $true)][string]$PythonVersion,
        [Parameter(Mandatory = $true)][pscustomobject]$Target,
        [Parameter(Mandatory = $true)][string]$OutputDir
    )

    $AttemptDir = Join-Path ([System.IO.Path]::GetTempPath()) "pip-download-$([guid]::NewGuid().ToString("N"))"
    New-Item -ItemType Directory -Path $AttemptDir -Force | Out-Null
    try {
        $IndexArguments = if (Test-PytorchRequirement -Requirement $Requirement) {
            @("--extra-index-url", $PytorchCpuIndexUrl)
        } else {
            @()
        }
        $Arguments = @(
            "-m",
            "pip",
            "download",
            "--dest", $AttemptDir
        ) + $IndexArguments + @("--no-deps") + (Get-PipTargetArguments -Target $Target -PythonVersion $PythonVersion) + @($Requirement)

        & $PythonCommand.FilePath @(@($PythonCommand.Arguments) + $Arguments)
        if ($LASTEXITCODE -eq 0) {
            $Files = @(Get-ChildItem -Path $AttemptDir -File -Filter "*.whl" -Recurse -ErrorAction SilentlyContinue)
            if ($Files.Count -gt 0) {
                Copy-Item -Path $Files.FullName -Destination $OutputDir -Force
                return $true
            }
        }
    } finally {
        Remove-Item -Recurse -Force -Path $AttemptDir -ErrorAction SilentlyContinue
    }

    Write-Warning "skip PyPI package: requirement=$Requirement python=$PythonVersion platform=$($Target.Platform)"
    return $false
}

<#
.SYNOPSIS
wheelだけでは取得条件を満たせないrequirementのsource archiveを取得します。
.PARAMETER PythonCommand
Python command情報です。
.PARAMETER Requirement
取得するrequirement specです。
.PARAMETER PythonVersion
取得対象Python versionです。
.PARAMETER OutputDir
保存先directoryです。
.OUTPUTS
source archiveを取得できた場合は`Downloaded`、対象Python version非対応の場合は`UnsupportedPython`、取得できない場合は`Missing`を返します。
#>
function Save-RequirementSourceArchive {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$PythonCommand,
        [Parameter(Mandatory = $true)][string]$Requirement,
        [Parameter(Mandatory = $true)][string]$PythonVersion,
        [Parameter(Mandatory = $true)][string]$OutputDir
    )

    $Parts = Get-PinnedRequirementParts -Requirement $Requirement
    if (-not $Parts) {
        Write-Warning "skip PyPI source archive for non-pinned requirement: requirement=$Requirement python=$PythonVersion"
        return "Missing"
    }

    try {
        $Version = [uri]::EscapeDataString($Parts.Version)
        $Metadata = Invoke-RestMethod -Uri "https://pypi.org/pypi/$($Parts.Name)/$Version/json"
        $SourceFile = @($Metadata.urls | Where-Object { $_.packagetype -eq "sdist" } | Select-Object -First 1)
        if ($SourceFile.Count -eq 0) {
            Write-Warning "skip PyPI source archive: requirement=$Requirement python=$PythonVersion"
            return "Missing"
        }

        $RequiresPython = if ($SourceFile[0].requires_python) {
            $SourceFile[0].requires_python
        } else {
            $Metadata.info.requires_python
        }
        if (-not (Test-PythonVersionRequirement -PythonCommand $PythonCommand -RequiresPython $RequiresPython -PythonVersion $PythonVersion)) {
            return "UnsupportedPython"
        }
        $Destination = Join-Path $OutputDir $SourceFile[0].filename
        Invoke-WebRequest -Uri $SourceFile[0].url -OutFile $Destination
        return "Downloaded"
    } catch {
        Write-Warning "skip PyPI source archive: requirement=$Requirement python=$PythonVersion"
        return "Missing"
    }
}

$ProjectDirectory = [System.IO.Path]::GetFullPath($ProjectDirectory)
if (-not (Test-Path -Path $ProjectDirectory -PathType Container)) {
    throw "ProjectDirectory was not found: $ProjectDirectory"
}

$RequirementsPath = Resolve-RequirementsPath -ProjectDirectory $ProjectDirectory
$Requirements = Get-RequirementSpecs -Path $RequirementsPath
if ($Requirements.Count -eq 0) {
    throw "requirements.txtにdownload対象packageがありません: $RequirementsPath"
}

$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$PythonCommand = Get-PythonCommand
foreach ($PythonVersion in $PythonVersions) {
    foreach ($Requirement in $Requirements) {
        $SucceededGroups = @{}
        foreach ($Target in $PlatformTargets) {
            Write-Host "Download PyPI package: requirement=$Requirement python=$PythonVersion platform=$($Target.Platform)"
            if (Save-RequirementForTarget -PythonCommand $PythonCommand -Requirement $Requirement -PythonVersion $PythonVersion -Target $Target -OutputDir $OutputDir) {
                $SucceededGroups[$Target.Group] = $true
                if ($Target.Group -eq "any") {
                    break
                }
            }
        }

        if ($SucceededGroups.ContainsKey("any")) {
            continue
        }
        if ($SucceededGroups.ContainsKey("windows") -and $SucceededGroups.ContainsKey("linux")) {
            continue
        }
        $SourceArchiveResult = Save-RequirementSourceArchive -PythonCommand $PythonCommand -Requirement $Requirement -PythonVersion $PythonVersion -OutputDir $OutputDir
        if ($SourceArchiveResult -eq "Downloaded") {
            continue
        }
        if ($SourceArchiveResult -eq "UnsupportedPython") {
            Write-Warning "skip PyPI package for unsupported Python version: requirement=$Requirement python=$PythonVersion"
            continue
        }

        throw "PyPI package archiveの取得条件を満たせません: requirement=$Requirement python=$PythonVersion"
    }
}

$DownloadedFiles = @(
    Get-ChildItem -Path $OutputDir -File -Include "*.whl", "*.tar.gz", "*.zip" -Recurse -ErrorAction SilentlyContinue
)

if ($DownloadedFiles.Count -eq 0) {
    throw "PyPI package archiveが作成されませんでした: $OutputDir"
}
