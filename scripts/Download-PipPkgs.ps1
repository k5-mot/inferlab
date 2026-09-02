<#
.SYNOPSIS
このrepositoryのair-gap運用に必要なPython package資材を取得します。

.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Download-PipPkgs.ps1 -OutputDir C:\airgap

Dify plugin、private-chat、OpenKBのPython依存を`C:\airgap\pypi`へ取得します。

.NOTES
download対象はこのscriptの`$Packages`で固定します。
#>
[CmdletBinding()]
param (
    [string]$OutputDir,
    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}
if (-not $OutputDir) {
    throw "OutputDir is required."
}

$ErrorActionPreference = "Stop"
$PythonVersions = @("3.12", "3.13", "3.14", "3.15")
$Registries = @(
    "https://pypi.org/simple",
    "https://download.pytorch.org/whl/cpu",
    "https://pypi.org/pypi"
)
$PytorchCpuIndexUrl = $Registries[1]
$PypiMetadataUrl = $Registries[2]
$PlatformTargets = @(
    [pscustomobject]@{ Group = "any"; Platform = "any"; Implementation = "py"; Abis = @("none") },
    [pscustomobject]@{ Group = "windows"; Platform = "win32"; Implementation = "cp"; Abis = @() },
    [pscustomobject]@{ Group = "windows"; Platform = "win_amd64"; Implementation = "cp"; Abis = @() },
    [pscustomobject]@{ Group = "linux"; Platform = "manylinux_2_34_x86_64"; Implementation = "cp"; Abis = @() },
    [pscustomobject]@{ Group = "linux"; Platform = "manylinux_2_28_x86_64"; Implementation = "cp"; Abis = @() },
    [pscustomobject]@{ Group = "linux"; Platform = "manylinux_2_24_x86_64"; Implementation = "cp"; Abis = @() },
    [pscustomobject]@{ Group = "linux"; Platform = "manylinux_2_17_x86_64"; Implementation = "cp"; Abis = @() },
    [pscustomobject]@{ Group = "linux"; Platform = "manylinux2014_x86_64"; Implementation = "cp"; Abis = @() }
)
$Packages = @(
    "annotated-doc==0.0.5",
    "annotated-types==0.8.0",
    "alembic>=1.14.0",
    "anyio==4.14.2",
    "apscheduler==3.11.3",
    "boto3>=1.43.78",
    "certifi==2026.7.22",
    "chardet",
    "click==8.4.2",
    "cohere>=5.21.1",
    "colorama==0.4.6",
    "docling>=2.117.0,<3.0.0",
    "fastapi[standard]==0.141.1",
    "fastembed",
    "h11==0.16.0",
    "httpcore==1.0.9",
    "httptools==0.8.0",
    "httpx==0.28.1",
    "idna==3.19",
    "langchain>=0.3.0",
    "langchain-cohere>=0.6.0",
    "langchain-community>=0.3.0",
    "langchain-core>=0.3.0",
    "langchain-openai>=1.6.0",
    "langchain-qdrant>=1.1.0",
    "langchain-text-splitters>=0.3.0",
    "langgraph",
    "langfuse>=3.0.0",
    "mecab-python3",
    "neologdn",
    "openai>=2.52.0",
    "openpyxl",
    "pandas",
    "pdfplumber",
    "psycopg[binary]>=3.2.0",
    "pydantic-core==2.46.4",
    "pydantic-settings>=2.6.0",
    "pydantic==2.13.4",
    "pypdf",
    "python-docx",
    "python-dotenv==1.2.3",
    "python-jose[cryptography]>=3.3.0",
    "python-multipart>=0.0.12",
    "python-pptx",
    "pyyaml==6.0.3",
    "qdrant-client>=1.12.0",
    "requests",
    "rq>=2.0.0",
    "slowapi",
    "sqlalchemy>=2.0.36",
    "starlette==1.6.0",
    "stopwordiso",
    "torch>=2.2.2,<3.0.0",
    "torchvision>=0.17.2,<1.0.0",
    "typing-extensions==4.16.0",
    "typing-inspection==0.4.4",
    "tzdata==2026.3",
    "tzlocal==5.4.4",
    "uvicorn[standard]==0.52.3",
    "uvloop==0.22.1; sys_platform != 'win32'",
    "valkey>=6.1.1",
    "watchdog",
    "watchfiles==1.2.0",
    "websockets==17.0.1"
)
if ($env:INFERLAB_DOWNLOAD_TEST) {
    $PythonVersions = @("3.12")
    $PlatformTargets = @(
        [pscustomobject]@{ Group = "any"; Platform = "any"; Implementation = "py"; Abis = @("none") }
    )
    $Packages = @("six==1.16.0")
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
requirement markerがdownload targetに一致するか判定します。
.PARAMETER PythonCommand
marker評価に使用するPython command情報です。
.PARAMETER Requirement
判定するrequirement specです。
.PARAMETER PythonVersion
取得対象Python versionです。
.PARAMETER Target
取得対象platform情報です。
.OUTPUTS
targetへ適用するrequirementならtrueを返します。
#>
function Test-RequirementTargetMarker {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$PythonCommand,
        [Parameter(Mandatory = $true)][string]$Requirement,
        [Parameter(Mandatory = $true)][string]$PythonVersion,
        [Parameter(Mandatory = $true)][pscustomobject]$Target
    )

    $TargetEnvironment = switch ($Target.Platform) {
        "win32" { @("win32", "Windows", "nt", "win32") }
        "win_amd64" { @("win32", "Windows", "nt", "AMD64") }
        default { @("linux", "Linux", "posix", "x86_64") }
    }
    $Code = "from pip._vendor.packaging.markers import default_environment; from pip._vendor.packaging.requirements import Requirement; import sys; env=default_environment(); env.update({'python_version':sys.argv[2], 'python_full_version':sys.argv[2]+'.0', 'sys_platform':sys.argv[3], 'platform_system':sys.argv[4], 'os_name':sys.argv[5], 'platform_machine':sys.argv[6], 'platform_python_implementation':'CPython', 'implementation_name':'cpython', 'implementation_version':sys.argv[2]+'.0'}); marker=Requirement(sys.argv[1]).marker; print('true' if marker is None or marker.evaluate(env) else 'false')"
    $Result = & $PythonCommand.FilePath @(
        @($PythonCommand.Arguments) +
        @("-c", $Code, $Requirement, $PythonVersion) +
        $TargetEnvironment
    )
    if ($LASTEXITCODE -ne 0) {
        throw "requirement markerを評価できません: requirement=$Requirement python=$PythonVersion platform=$($Target.Platform)"
    }

    return $Result.Trim() -eq "true"
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
        $DownloadRequirement = ($Requirement -split ";", 2)[0].Trim()
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
        ) + $IndexArguments + @("--no-deps") + (Get-PipTargetArguments -Target $Target -PythonVersion $PythonVersion) + @($DownloadRequirement)

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
        $Metadata = Invoke-RestMethod -Uri "$PypiMetadataUrl/$($Parts.Name)/$Version/json"
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
        Invoke-WebRequest -Uri $SourceFile[0].url -OutFile $Destination -UseBasicParsing
        return "Downloaded"
    } catch {
        Write-Warning "skip PyPI source archive: requirement=$Requirement python=$PythonVersion"
        return "Missing"
    }
}

$OutputDir = Join-Path ([System.IO.Path]::GetFullPath($OutputDir)) "pypi"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$PythonCommand = Get-PythonCommand
foreach ($PythonVersion in $PythonVersions) {
    foreach ($Requirement in $Packages) {
        $SucceededGroups = @{}
        $ApplicableGroups = @{}
        $ApplicableTargetCount = 0
        foreach ($Target in $PlatformTargets) {
            if (-not (Test-RequirementTargetMarker -PythonCommand $PythonCommand -Requirement $Requirement -PythonVersion $PythonVersion -Target $Target)) {
                continue
            }
            $ApplicableTargetCount += 1
            $ApplicableGroups[$Target.Group] = $true
            Write-Host "Download PyPI package: requirement=$Requirement python=$PythonVersion platform=$($Target.Platform)"
            if (Save-RequirementForTarget -PythonCommand $PythonCommand -Requirement $Requirement -PythonVersion $PythonVersion -Target $Target -OutputDir $OutputDir) {
                $SucceededGroups[$Target.Group] = $true
            }
        }

        if ($ApplicableTargetCount -eq 0) {
            continue
        }
        if ($SucceededGroups.ContainsKey("any")) {
            continue
        }
        $RequiredPlatformGroups = @($ApplicableGroups.Keys | Where-Object { $_ -ne "any" })
        $MissingPlatformGroups = @($RequiredPlatformGroups | Where-Object { -not $SucceededGroups.ContainsKey($_) })
        if ($RequiredPlatformGroups.Count -gt 0 -and $MissingPlatformGroups.Count -eq 0) {
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
