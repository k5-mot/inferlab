#requires -Version 5.1
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [uri]$NextcloudBaseUrl,

    [string]$NextcloudUser,

    [string]$RemotePath = "/AD-Files",

    [Parameter(Mandatory = $true)]
    [string]$NextcloudCredentialPath,

    [string]$SourceCredentialPath,

    [string]$TaskName = "Inferlab Nextcloud AD File Sync",

    [string]$ScriptPath = (Join-Path $PSScriptRoot "sync-ad-files-to-nextcloud.ps1"),

    [int]$IntervalMinutes = 30,

    [string]$RunAsUser = "$env:USERDOMAIN\$env:USERNAME"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

<#
.SYNOPSIS
SecureString を一時的に平文へ変換します。

.DESCRIPTION
Windows PowerShell 5.1 には ConvertFrom-SecureString の AsPlainText がないため、タスク登録に必要な場面だけ復号します。

.PARAMETER SecureString
復号する SecureString です。

.OUTPUTS
復号した文字列を返します。

.NOTES
アンマネージ メモリ上の復号領域は finally ブロックで破棄します。
#>
function ConvertTo-PlainText {
    param (
        [Parameter(Mandatory = $true)]
        [securestring]$SecureString
    )

    $Pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Pointer)
    }
}

<#
.SYNOPSIS
タスク スケジューラに渡す PowerShell 引数を引用付きで組み立てます。

.DESCRIPTION
パスや URL に空白が含まれても powershell.exe が正しく解釈できるよう、各値を安全に単引用符で囲みます。

.PARAMETER Values
引数名と値を持つ順序付きハッシュテーブルです。

.OUTPUTS
powershell.exe に渡す引数文字列を返します。

.NOTES
真偽値スイッチは値が $true の場合だけ引数として出力します。
#>
function ConvertTo-TaskArgument {
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Values
    )

    $Parts = New-Object "System.Collections.Generic.List[string]"
    foreach ($Item in $Values.GetEnumerator()) {
        if ($null -eq $Item.Value -or $Item.Value -eq "") {
            continue
        }

        if ($Item.Value -is [bool]) {
            if ($Item.Value) {
                $Parts.Add("-{0}" -f $Item.Key)
            }
            continue
        }

        $Escaped = ([string]$Item.Value) -replace "'", "''"
        $Parts.Add("-{0} '{1}'" -f $Item.Key, $Escaped)
    }

    return ($Parts -join " ")
}

<#
.SYNOPSIS
Nextcloud 同期用の Windows タスクを登録します。

.DESCRIPTION
指定された同期スクリプトを 30 分などの一定間隔で単発起動するタスクとして登録します。

.PARAMETER ActionArguments
同期スクリプトへ渡す引数文字列です。

.OUTPUTS
登録された ScheduledTask オブジェクトを返します。

.NOTES
タスク実行ユーザーのパスワードを対話入力し、保存済み資格情報を復号できる同一ユーザーで実行します。
#>
function Register-NextcloudAdFileSyncTask {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ActionArguments
    )

    $TaskCredential = Get-Credential -UserName $RunAsUser -Message "タスクを実行する Windows アカウントの資格情報を入力してください。"
    $TaskPassword = ConvertTo-PlainText -SecureString $TaskCredential.Password

    $Action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $ScriptPath, $ActionArguments)
    $Trigger = New-ScheduledTaskTrigger `
        -Once `
        -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $Settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 12)

    return Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $Action `
        -Trigger $Trigger `
        -Settings $Settings `
        -User $TaskCredential.UserName `
        -Password $TaskPassword `
        -Description "AD 認証付きファイルサーバーから Nextcloud へファイルをコピーします。" `
        -Force
}

if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "同期スクリプトが見つかりません: $ScriptPath"
}

if (-not (Test-Path -LiteralPath $NextcloudCredentialPath -PathType Leaf)) {
    throw "Nextcloud 資格情報ファイルが見つかりません: $NextcloudCredentialPath"
}

if ($SourceCredentialPath -and -not (Test-Path -LiteralPath $SourceCredentialPath -PathType Leaf)) {
    throw "AD 共有資格情報ファイルが見つかりません: $SourceCredentialPath"
}

$Arguments = ConvertTo-TaskArgument -Values ([ordered]@{
    SourcePath = $SourcePath
    NextcloudBaseUrl = $NextcloudBaseUrl.AbsoluteUri
    NextcloudUser = $NextcloudUser
    RemotePath = $RemotePath
    NextcloudCredentialPath = $NextcloudCredentialPath
    SourceCredentialPath = $SourceCredentialPath
})

Register-NextcloudAdFileSyncTask -ActionArguments $Arguments
