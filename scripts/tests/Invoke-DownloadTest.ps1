<#
.SYNOPSIS
download smoke test用の一時directoryを作成します。
.PARAMETER Name
一時directory名に含めるtest名です。
.OUTPUTS
作成した一時directoryの絶対pathを返します。
.NOTES
呼び出し元はtest終了後にRemove-DownloadTestDirectoryで削除します。
#>
$ErrorActionPreference = "Stop"

function New-DownloadTestDirectory {
    param (
        [Parameter(Mandatory = $true)][string]$Name
    )

    $Directory = Join-Path ([System.IO.Path]::GetTempPath()) "inferlab-download-$Name-$([guid]::NewGuid().ToString("N"))"
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    return $Directory
}

<#
.SYNOPSIS
download smoke test用の一時directoryを削除します。
.PARAMETER Path
削除する一時directoryのpathです。
.OUTPUTS
値を返しません。
.NOTES
存在しないdirectoryは無視します。
#>
function Remove-DownloadTestDirectory {
    param (
        [Parameter(Mandatory = $true)][string]$Path
    )

    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

<#
.SYNOPSIS
指定commandが実行可能か確認します。
.PARAMETER Name
確認するcommand名です。
.OUTPUTS
実行可能なcommandが見つかった場合はtrue、それ以外はfalseを返します。
#>
function Test-DownloadCommand {
    param (
        [Parameter(Mandatory = $true)][string]$Name
    )

    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

<#
.SYNOPSIS
Python 3 commandが実行可能か確認します。
.OUTPUTS
実行可能なPython 3 commandが見つかった場合はtrue、それ以外はfalseを返します。
.NOTES
WindowsのApp Execution Aliasを避けるため、--versionの終了codeまで確認します。
#>
function Test-Python3Command {
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
            return $true
        }
    }

    return $false
}

<#
.SYNOPSIS
依存commandが無いdownload smoke testをskipします。
.PARAMETER Command
必要なcommand名です。
.OUTPUTS
skipした場合はtrue、それ以外はfalseを返します。
#>
function Skip-DownloadTestIfCommandMissing {
    param (
        [Parameter(Mandatory = $true)][string]$Command
    )

    if (Test-DownloadCommand -Name $Command) {
        return $false
    }

    Write-Host "Skip download test because command is missing: $Command"
    return $true
}

<#
.SYNOPSIS
download scriptをsmoke test modeで実行します。
.PARAMETER ScriptName
scripts directoryにあるdownload scriptのfile名です。
.PARAMETER OutputDir
download先のbase directoryです。
.PARAMETER Arguments
scriptへ追加で渡すargument配列です。
.OUTPUTS
値を返しません。
.NOTES
INFERLAB_DOWNLOAD_TESTを一時的に有効化します。
#>
function Invoke-DownloadTestScript {
    param (
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [string[]]$Arguments = @()
    )

    $PreviousValue = $env:INFERLAB_DOWNLOAD_TEST
    $env:INFERLAB_DOWNLOAD_TEST = "1"
    try {
        $ScriptPath = Join-Path $PSScriptRoot "../$ScriptName"
        & $ScriptPath -OutputDir $OutputDir @Arguments
        if (-not $?) {
            throw "download script failed: $ScriptName"
        }
    }
    finally {
        $env:INFERLAB_DOWNLOAD_TEST = $PreviousValue
    }
}

<#
.SYNOPSIS
download smoke testの成果物fileが存在することを検証します。
.PARAMETER Directory
成果物fileを確認するdirectoryです。
.PARAMETER Pattern
確認するfile patternです。
.OUTPUTS
値を返しません。
.NOTES
成果物が無い場合は例外を送出します。
#>
function Assert-DownloadTestArtifacts {
    param (
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string[]]$Pattern
    )

    $Files = @()
    foreach ($ItemPattern in $Pattern) {
        $Files += @(Get-ChildItem -Path $Directory -Filter $ItemPattern -File -Recurse -ErrorAction SilentlyContinue)
    }

    if ($Files.Count -eq 0) {
        throw "download test artifacts were not created: $Directory ($($Pattern -join ', '))"
    }
}
