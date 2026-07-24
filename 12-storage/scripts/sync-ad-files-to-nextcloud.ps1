#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [uri]$NextcloudBaseUrl,

    [string]$NextcloudUser,

    [string]$RemotePath = "/AD-Files",

    [System.Management.Automation.PSCredential]$NextcloudCredential,

    [string]$NextcloudCredentialPath,

    [System.Management.Automation.PSCredential]$SourceCredential,

    [string]$SourceCredentialPath,

    [string]$DriveName = "ADSYNC",

    [int]$IntervalMinutes = 30,

    [switch]$Continuous,

    [switch]$OverwriteRemoteNewer,

    [string]$LogDirectory = "${env:ProgramData}\Inferlab\NextcloudAdSync\logs",

    [int]$TimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Net.Http

<#
.SYNOPSIS
同期処理のログをファイルと標準出力へ書き込みます。

.DESCRIPTION
運用時にタスク スケジューラの履歴だけへ依存しないよう、日付単位のログファイルへ追記します。

.PARAMETER Message
記録するメッセージです。

.PARAMETER Level
ログレベルです。INFO、WARN、ERROR のような短い値を想定します。

.OUTPUTS
なし。

.NOTES
ログディレクトリが存在しない場合は作成します。
#>
function Write-SyncLog {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string]$Level = "INFO"
    )

    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "[{0}] [{1}] {2}" -f $Timestamp, $Level, $Message
    $LogPath = Join-Path $LogDirectory ("sync-{0}.log" -f (Get-Date -Format "yyyyMMdd"))

    Add-Content -Path $LogPath -Value $Line -Encoding UTF8
    Write-Host $Line
}

<#
.SYNOPSIS
SecureString を一時的に平文へ変換します。

.DESCRIPTION
Basic 認証ヘッダーとタスク登録 API は平文の資格情報を要求するため、必要な場面だけ復号します。

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
指定された方法から PSCredential を取得します。

.DESCRIPTION
対話実行では資格情報オブジェクトまたはプロンプトを使い、タスク実行では Export-Clixml で保存した資格情報を読み込みます。

.PARAMETER Credential
呼び出し元から直接渡された資格情報です。

.PARAMETER CredentialPath
Export-Clixml で保存した資格情報ファイルのパスです。

.PARAMETER PromptMessage
資格情報を対話入力するときに表示するメッセージです。

.PARAMETER Mandatory
資格情報が必須かどうかを示します。

.OUTPUTS
取得した PSCredential、または必須ではなく未指定の場合は $null を返します。

.NOTES
資格情報ファイルは保存時と同じ Windows ユーザーで実行した場合だけ復号できます。
#>
function Resolve-SyncCredential {
    param (
        [System.Management.Automation.PSCredential]$Credential,

        [string]$CredentialPath,

        [Parameter(Mandatory = $true)]
        [string]$PromptMessage,

        [switch]$Mandatory
    )

    if ($Credential) {
        return $Credential
    }

    if ($CredentialPath) {
        if (-not (Test-Path -LiteralPath $CredentialPath)) {
            throw "資格情報ファイルが見つかりません: $CredentialPath"
        }

        return Import-Clixml -LiteralPath $CredentialPath
    }

    if ($Mandatory) {
        return Get-Credential -Message $PromptMessage
    }

    return $null
}

<#
.SYNOPSIS
Nextcloud WebDAV 用の Basic 認証ヘッダーを作成します。

.DESCRIPTION
Nextcloud の WebDAV API は Basic 認証またはセッション Cookie を受け付けるため、スクリプト実行に向いた Basic 認証ヘッダーを生成します。

.PARAMETER Credential
Nextcloud のユーザー名とアプリ パスワードを含む資格情報です。

.OUTPUTS
Authorization ヘッダーを含むハッシュテーブルを返します。

.NOTES
OIDC や 2FA を使う環境では通常のログイン パスワードではなくアプリ パスワードを使います。
#>
function New-BasicAuthHeader {
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$Credential
    )

    $Password = ConvertTo-PlainText -SecureString $Credential.Password
    $TokenBytes = [Text.Encoding]::UTF8.GetBytes(("{0}:{1}" -f $Credential.UserName, $Password))
    $Token = [Convert]::ToBase64String($TokenBytes)

    return @{
        Authorization = "Basic $Token"
    }
}

<#
.SYNOPSIS
WebDAV パスの 1 セグメントを URL エンコードします。

.DESCRIPTION
ファイル名に含まれる空白、#、日本語などを URL のパスとして安全に扱うため、区切り文字ごとにエンコードします。

.PARAMETER Segment
エンコードするパス セグメントです。

.OUTPUTS
URL エンコード済みの文字列を返します。

.NOTES
スラッシュはパス区切りとして扱うため、この関数には含めないでください。
#>
function ConvertTo-WebDavPathSegment {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Segment
    )

    return [System.Uri]::EscapeDataString($Segment)
}

<#
.SYNOPSIS
複数のパス要素を Nextcloud WebDAV 用の相対パスへ結合します。

.DESCRIPTION
Windows のバックスラッシュと URL のスラッシュが混ざらないよう、パス要素を正規化してから結合します。

.PARAMETER Parts
結合するパス要素です。

.OUTPUTS
先頭スラッシュなしの WebDAV 相対パスを返します。

.NOTES
空のパス要素は無視します。
#>
function Join-WebDavPath {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Parts
    )

    $Segments = New-Object "System.Collections.Generic.List[string]"
    foreach ($Part in $Parts) {
        if ([string]::IsNullOrWhiteSpace($Part)) {
            continue
        }

        foreach ($Segment in ($Part -replace "\\", "/" -split "/")) {
            if (-not [string]::IsNullOrWhiteSpace($Segment)) {
                $Segments.Add($Segment)
            }
        }
    }

    return ($Segments -join "/")
}

<#
.SYNOPSIS
Nextcloud WebDAV のファイルまたはフォルダー URL を作成します。

.DESCRIPTION
Nextcloud の標準 WebDAV エンドポイントである remote.php/dav/files/{user}/... 形式の URL を生成します。

.PARAMETER BaseUrl
Nextcloud のベース URL です。

.PARAMETER User
Nextcloud の WebDAV ユーザー ID です。

.PARAMETER RelativePath
ユーザー配下のファイルまたはフォルダー相対パスです。

.OUTPUTS
WebDAV リソースを指す Uri を返します。

.NOTES
BaseUrl の末尾スラッシュ有無は問いません。
#>
function Get-WebDavFileUri {
    param (
        [Parameter(Mandatory = $true)]
        [uri]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$User,

        [string]$RelativePath
    )

    $Builder = [System.UriBuilder]::new($BaseUrl)
    $BasePath = $Builder.Path.TrimEnd([char[]]@("/"))
    $EncodedUser = ConvertTo-WebDavPathSegment -Segment $User
    $EncodedPath = ""

    if (-not [string]::IsNullOrWhiteSpace($RelativePath)) {
        $EncodedSegments = foreach ($Segment in ($RelativePath -replace "\\", "/" -split "/")) {
            if (-not [string]::IsNullOrWhiteSpace($Segment)) {
                ConvertTo-WebDavPathSegment -Segment $Segment
            }
        }
        $EncodedPath = "/" + ($EncodedSegments -join "/")
    }

    $Builder.Path = "{0}/remote.php/dav/files/{1}{2}" -f $BasePath, $EncodedUser, $EncodedPath
    return $Builder.Uri
}

<#
.SYNOPSIS
WebDAV リクエストを送信します。

.DESCRIPTION
標準メソッドに加えて MKCOL などの WebDAV メソッドを扱えるよう、HttpClient でリクエストを構築します。

.PARAMETER Method
送信する HTTP/WebDAV メソッドです。

.PARAMETER Uri
送信先 URI です。

.PARAMETER Headers
追加する HTTP ヘッダーです。

.PARAMETER InputFile
PUT などで送信するローカルファイルです。

.PARAMETER Body
PROPFIND などで送信する文字列ボディです。

.PARAMETER ExpectedStatusCodes
正常として扱う HTTP ステータスコードです。

.OUTPUTS
ステータスコード、本文、ヘッダーを持つ PSCustomObject を返します。

.NOTES
想定外のステータスコードを受け取った場合は例外を送出します。
#>
function Invoke-WebDavRequest {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [uri]$Uri,

        [hashtable]$Headers = @{},

        [string]$InputFile,

        [string]$Body,

        [int[]]$ExpectedStatusCodes = @(200, 201, 204, 207)
    )

    $Client = New-Object System.Net.Http.HttpClient
    $Client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $HttpMethod = New-Object System.Net.Http.HttpMethod -ArgumentList $Method
    $Request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList @($HttpMethod, $Uri)
    $Stream = $null

    try {
        foreach ($Header in $Headers.GetEnumerator()) {
            [void]$Request.Headers.TryAddWithoutValidation($Header.Key, [string]$Header.Value)
        }

        if ($InputFile) {
            $Stream = [System.IO.File]::Open($InputFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $Request.Content = New-Object System.Net.Http.StreamContent -ArgumentList $Stream
        }
        elseif ($Body) {
            $Request.Content = New-Object System.Net.Http.StringContent -ArgumentList @($Body, [Text.Encoding]::UTF8, "application/xml")
        }

        $Response = $Client.SendAsync($Request).GetAwaiter().GetResult()
        $StatusCode = [int]$Response.StatusCode
        $Content = ""
        $ContentHeaders = $null

        if ($Response.Content) {
            $ContentHeaders = $Response.Content.Headers
            $Content = $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }

        if ($ExpectedStatusCodes -notcontains $StatusCode) {
            throw "WebDAV リクエストに失敗しました。Method=$Method Status=$StatusCode Uri=$Uri Body=$Content"
        }

        return [pscustomobject]@{
            StatusCode = $StatusCode
            Content = $Content
            Headers = $Response.Headers
            ContentHeaders = $ContentHeaders
        }
    }
    finally {
        if ($Stream) {
            $Stream.Dispose()
        }

        if ($Request) {
            $Request.Dispose()
        }

        if ($Client) {
            $Client.Dispose()
        }
    }
}

<#
.SYNOPSIS
Nextcloud 上のファイル情報を取得します。

.DESCRIPTION
HEAD リクエストでリモートファイルの存在、サイズ、更新日時を取得し、アップロード要否の判定に使います。

.PARAMETER Uri
確認対象の WebDAV URI です。

.PARAMETER Headers
認証などの HTTP ヘッダーです。

.OUTPUTS
存在有無、サイズ、更新日時を持つ PSCustomObject を返します。

.NOTES
404 は存在しないファイルとして扱い、それ以外の想定外ステータスは例外にします。
#>
function Get-WebDavItemInfo {
    param (
        [Parameter(Mandatory = $true)]
        [uri]$Uri,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $Response = Invoke-WebDavRequest -Method "HEAD" -Uri $Uri -Headers $Headers -ExpectedStatusCodes @(200, 404)
    if ($Response.StatusCode -eq 404) {
        return [pscustomobject]@{
            Exists = $false
            Length = $null
            LastModifiedUtc = $null
        }
    }

    $LastModifiedUtc = $null
    if ($Response.ContentHeaders -and $Response.ContentHeaders.LastModified) {
        $LastModifiedUtc = $Response.ContentHeaders.LastModified.UtcDateTime
    }

    $ContentLength = $null
    if ($Response.ContentHeaders) {
        $ContentLength = $Response.ContentHeaders.ContentLength
    }

    return [pscustomobject]@{
        Exists = $true
        Length = $ContentLength
        LastModifiedUtc = $LastModifiedUtc
    }
}

<#
.SYNOPSIS
Nextcloud 上のフォルダー階層を作成します。

.DESCRIPTION
WebDAV の MKCOL は親フォルダーが必要なため、上位から順番にフォルダーを作成します。

.PARAMETER BaseUrl
Nextcloud のベース URL です。

.PARAMETER User
Nextcloud の WebDAV ユーザー ID です。

.PARAMETER DirectoryPath
作成するユーザー配下のフォルダー相対パスです。

.PARAMETER Headers
認証などの HTTP ヘッダーです。

.OUTPUTS
なし。

.NOTES
既存フォルダーは 405 として返ることがあるため正常扱いにします。
#>
function Ensure-WebDavDirectory {
    param (
        [Parameter(Mandatory = $true)]
        [uri]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$User,

        [string]$DirectoryPath,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $CurrentPath = ""
    foreach ($Segment in ($DirectoryPath -replace "\\", "/" -split "/")) {
        if ([string]::IsNullOrWhiteSpace($Segment)) {
            continue
        }

        $CurrentPath = Join-WebDavPath -Parts @($CurrentPath, $Segment)
        $Uri = Get-WebDavFileUri -BaseUrl $BaseUrl -User $User -RelativePath $CurrentPath
        [void](Invoke-WebDavRequest -Method "MKCOL" -Uri $Uri -Headers $Headers -ExpectedStatusCodes @(201, 405))
    }
}

<#
.SYNOPSIS
UNC パスから共有ルートを取り出します。

.DESCRIPTION
資格情報付きでネットワーク共有を割り当てる際は \\server\share までを PSDrive のルートにする必要があります。

.PARAMETER Path
解析対象の UNC パスです。

.OUTPUTS
\\server\share 形式の共有ルートを返します。

.NOTES
UNC ではないパスを渡した場合は例外を送出します。
#>
function Get-UncRoot {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($Path -notmatch "^\\\\([^\\]+)\\([^\\]+)(\\.*)?$") {
        throw "UNC パスではありません: $Path"
    }

    return "\\{0}\{1}" -f $Matches[1], $Matches[2]
}

<#
.SYNOPSIS
必要に応じて AD 認証付きファイル共有を PSDrive として割り当てます。

.DESCRIPTION
タスク実行ユーザーに共有アクセス権がある場合は割り当てず、別資格情報が指定された場合だけ一時 PSDrive を作成します。

.PARAMETER Path
同期元のローカルパスまたは UNC パスです。

.PARAMETER Credential
共有へ接続する AD 資格情報です。

.PARAMETER Name
一時 PSDrive の名前です。

.OUTPUTS
実際に参照するローカルパス、割り当て有無、ドライブ名を持つ PSCustomObject を返します。

.NOTES
同名の PSDrive が既に存在する場合は誤接続を避けるため例外を送出します。
#>
function Mount-SourcePath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not $Credential) {
        return [pscustomobject]@{
            Path = $Path
            Mounted = $false
            DriveName = $null
        }
    }

    $Root = Get-UncRoot -Path $Path
    $ExistingDrive = Get-PSDrive -Name $Name -ErrorAction SilentlyContinue
    if ($ExistingDrive) {
        throw "PSDrive '$Name' は既に存在します。別の DriveName を指定してください。"
    }

    New-PSDrive -Name $Name -PSProvider FileSystem -Root $Root -Credential $Credential | Out-Null
    $Relative = $Path.Substring($Root.Length).TrimStart([char[]]@("\"))
    $MappedPath = if ($Relative) { "{0}:\{1}" -f $Name, $Relative } else { "{0}:\" -f $Name }

    return [pscustomobject]@{
        Path = $MappedPath
        Mounted = $true
        DriveName = $Name
    }
}

<#
.SYNOPSIS
一時的に割り当てた PSDrive を解除します。

.DESCRIPTION
同期処理後に資格情報付きの共有接続を残さないよう、Mount-SourcePath が作成した PSDrive だけを削除します。

.PARAMETER MountInfo
Mount-SourcePath が返した割り当て情報です。

.OUTPUTS
なし。

.NOTES
割り当てていない場合は何もしません。
#>
function Dismount-SourcePath {
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$MountInfo
    )

    if ($MountInfo.Mounted) {
        Remove-PSDrive -Name $MountInfo.DriveName -Force
    }
}

<#
.SYNOPSIS
同期元ルートから見た相対パスを計算します。

.DESCRIPTION
Nextcloud 側に同じフォルダー構造で配置するため、ローカルまたは UNC の絶対パスから相対パスを切り出します。

.PARAMETER BasePath
同期元のルートパスです。

.PARAMETER Path
対象ファイルのフルパスです。

.OUTPUTS
スラッシュ区切りの相対パスを返します。

.NOTES
対象ファイルが同期元ルート配下にない場合は例外を送出します。
#>
function Get-RelativeSourcePath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $FullBase = [System.IO.Path]::GetFullPath($BasePath).TrimEnd([char[]]@("\", "/"))
    $FullPath = [System.IO.Path]::GetFullPath($Path)

    if (-not $FullPath.StartsWith($FullBase, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "ファイルが同期元ルート配下にありません: $Path"
    }

    return ($FullPath.Substring($FullBase.Length).TrimStart([char[]]@("\", "/")) -replace "\\", "/")
}

<#
.SYNOPSIS
ローカルファイルを Nextcloud へアップロードすべきか判定します。

.DESCRIPTION
存在、サイズ、更新日時を比較し、リモート側が新しい場合は明示指定がない限り上書きを避けます。

.PARAMETER LocalFile
同期元のローカルファイルです。

.PARAMETER RemoteInfo
Nextcloud 上のファイル情報です。

.PARAMETER AllowRemoteNewerOverwrite
リモート側が新しい場合も上書きするかどうかです。

.OUTPUTS
アップロード要否、競合有無、理由を持つ PSCustomObject を返します。

.NOTES
ファイルシステムや WebDAV の丸め誤差を考慮し、更新日時は 2 秒以内を同一扱いにします。
#>
function Test-RemoteUploadRequired {
    param (
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$LocalFile,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$RemoteInfo,

        [bool]$AllowRemoteNewerOverwrite
    )

    if (-not $RemoteInfo.Exists) {
        return [pscustomobject]@{ Required = $true; Conflict = $false; Reason = "missing" }
    }

    $RemoteLastModifiedUtc = $RemoteInfo.LastModifiedUtc
    if ($RemoteLastModifiedUtc -and ($RemoteLastModifiedUtc -gt $LocalFile.LastWriteTimeUtc.AddSeconds(2)) -and -not $AllowRemoteNewerOverwrite) {
        return [pscustomobject]@{ Required = $false; Conflict = $true; Reason = "remote-newer" }
    }

    if ($RemoteInfo.Length -ne $LocalFile.Length) {
        return [pscustomobject]@{ Required = $true; Conflict = $false; Reason = "size-different" }
    }

    if (-not $RemoteLastModifiedUtc) {
        return [pscustomobject]@{ Required = $true; Conflict = $false; Reason = "mtime-unknown" }
    }

    $DeltaSeconds = [Math]::Abs(($LocalFile.LastWriteTimeUtc - $RemoteLastModifiedUtc).TotalSeconds)
    if ($DeltaSeconds -gt 2) {
        return [pscustomobject]@{ Required = $true; Conflict = $false; Reason = "mtime-different" }
    }

    return [pscustomobject]@{ Required = $false; Conflict = $false; Reason = "unchanged" }
}

<#
.SYNOPSIS
1 ファイルを Nextcloud へ同期します。

.DESCRIPTION
必要なリモートフォルダーを作成し、差分があるファイルだけ WebDAV PUT でアップロードします。

.PARAMETER File
同期元のファイル情報です。

.PARAMETER SourceRoot
同期元ルートの実パスです。

.PARAMETER BaseUrl
Nextcloud のベース URL です。

.PARAMETER User
Nextcloud の WebDAV ユーザー ID です。

.PARAMETER RootRemotePath
Nextcloud 側の配置先ルートです。

.PARAMETER Headers
認証などの HTTP ヘッダーです。

.PARAMETER AllowRemoteNewerOverwrite
リモート側が新しい場合も上書きするかどうかです。

.OUTPUTS
同期結果を表す PSCustomObject を返します。

.NOTES
アップロード時に X-OC-MTime を送信し、Nextcloud 側の更新日時を同期元に近づけます。
#>
function Sync-FileToNextcloud {
    param (
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [uri]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$User,

        [Parameter(Mandatory = $true)]
        [string]$RootRemotePath,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [bool]$AllowRemoteNewerOverwrite
    )

    $RelativePath = Get-RelativeSourcePath -BasePath $SourceRoot -Path $File.FullName
    $RemoteFilePath = Join-WebDavPath -Parts @($RootRemotePath, $RelativePath)
    $RemoteDirectory = Split-Path -Path $RemoteFilePath -Parent
    if ($RemoteDirectory) {
        Ensure-WebDavDirectory -BaseUrl $BaseUrl -User $User -DirectoryPath $RemoteDirectory -Headers $Headers
    }

    $RemoteUri = Get-WebDavFileUri -BaseUrl $BaseUrl -User $User -RelativePath $RemoteFilePath
    $RemoteInfo = Get-WebDavItemInfo -Uri $RemoteUri -Headers $Headers
    $Decision = Test-RemoteUploadRequired -LocalFile $File -RemoteInfo $RemoteInfo -AllowRemoteNewerOverwrite $AllowRemoteNewerOverwrite

    if ($Decision.Conflict) {
        Write-SyncLog -Level "WARN" -Message ("リモートが新しいためスキップ: {0}" -f $RemoteFilePath)
        return [pscustomobject]@{ Status = "Conflict"; LocalPath = $File.FullName; RemotePath = $RemoteFilePath; Bytes = $File.Length }
    }

    if (-not $Decision.Required) {
        return [pscustomobject]@{ Status = "Skipped"; LocalPath = $File.FullName; RemotePath = $RemoteFilePath; Bytes = $File.Length }
    }

    $UploadHeaders = @{}
    foreach ($Header in $Headers.GetEnumerator()) {
        $UploadHeaders[$Header.Key] = $Header.Value
    }

    $EpochSeconds = [int64][Math]::Floor(($File.LastWriteTimeUtc - [DateTime]"1970-01-01T00:00:00Z").TotalSeconds)
    $UploadHeaders["X-OC-MTime"] = [string]$EpochSeconds

    if ($PSCmdlet.ShouldProcess($RemoteFilePath, "Nextcloud へアップロード")) {
        [void](Invoke-WebDavRequest -Method "PUT" -Uri $RemoteUri -Headers $UploadHeaders -InputFile $File.FullName -ExpectedStatusCodes @(200, 201, 204))
        Write-SyncLog -Message ("アップロード完了: {0}" -f $RemoteFilePath)
    }

    return [pscustomobject]@{ Status = "Uploaded"; LocalPath = $File.FullName; RemotePath = $RemoteFilePath; Bytes = $File.Length }
}

<#
.SYNOPSIS
AD 認証付きファイルサーバーから Nextcloud へ一度だけ同期します。

.DESCRIPTION
同期元を必要に応じて一時 PSDrive に割り当て、配下のファイルを Nextcloud WebDAV へコピーします。

.PARAMETER ResolvedNextcloudCredential
Nextcloud WebDAV 用の資格情報です。

.PARAMETER ResolvedSourceCredential
AD ファイル共有へ接続する資格情報です。

.OUTPUTS
集計結果を表す PSCustomObject を返します。

.NOTES
削除同期は行わないため、同期元から消えたファイルは Nextcloud 側に残ります。
#>
function Invoke-NextcloudAdFileSync {
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$ResolvedNextcloudCredential,

        [System.Management.Automation.PSCredential]$ResolvedSourceCredential
    )

    $DavUser = if ($NextcloudUser) { $NextcloudUser } else { $ResolvedNextcloudCredential.UserName }
    $Headers = New-BasicAuthHeader -Credential $ResolvedNextcloudCredential
    $MountInfo = Mount-SourcePath -Path $SourcePath -Credential $ResolvedSourceCredential -Name $DriveName

    try {
        if (-not (Test-Path -LiteralPath $MountInfo.Path -PathType Container)) {
            throw "同期元フォルダーが見つかりません: $($MountInfo.Path)"
        }

        Write-SyncLog -Message ("同期開始: Source={0} Nextcloud={1} RemotePath={2}" -f $SourcePath, $NextcloudBaseUrl, $RemotePath)
        Ensure-WebDavDirectory -BaseUrl $NextcloudBaseUrl -User $DavUser -DirectoryPath $RemotePath -Headers $Headers

        $Files = Get-ChildItem -LiteralPath $MountInfo.Path -File -Recurse -Force
        $Results = foreach ($File in $Files) {
            Sync-FileToNextcloud `
                -File $File `
                -SourceRoot $MountInfo.Path `
                -BaseUrl $NextcloudBaseUrl `
                -User $DavUser `
                -RootRemotePath $RemotePath `
                -Headers $Headers `
                -AllowRemoteNewerOverwrite ([bool]$OverwriteRemoteNewer)
        }

        $Uploaded = @($Results | Where-Object { $_.Status -eq "Uploaded" }).Count
        $Skipped = @($Results | Where-Object { $_.Status -eq "Skipped" }).Count
        $Conflicts = @($Results | Where-Object { $_.Status -eq "Conflict" }).Count
        Write-SyncLog -Message ("同期完了: Uploaded={0} Skipped={1} Conflicts={2}" -f $Uploaded, $Skipped, $Conflicts)

        return [pscustomobject]@{
            Uploaded = $Uploaded
            Skipped = $Skipped
            Conflicts = $Conflicts
        }
    }
    finally {
        Dismount-SourcePath -MountInfo $MountInfo
    }
}

<#
.SYNOPSIS
指定間隔で Nextcloud への同期を繰り返します。

.DESCRIPTION
常駐実行が必要な環境向けに、同期完了後に指定分数だけ待機して再実行します。

.PARAMETER ResolvedNextcloudCredential
Nextcloud WebDAV 用の資格情報です。

.PARAMETER ResolvedSourceCredential
AD ファイル共有へ接続する資格情報です。

.OUTPUTS
なし。

.NOTES
Windows 運用ではタスク スケジューラで 30 分おきに単発実行する構成を推奨します。
#>
function Start-NextcloudAdFileSyncLoop {
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$ResolvedNextcloudCredential,

        [System.Management.Automation.PSCredential]$ResolvedSourceCredential
    )

    while ($true) {
        try {
            [void](Invoke-NextcloudAdFileSync -ResolvedNextcloudCredential $ResolvedNextcloudCredential -ResolvedSourceCredential $ResolvedSourceCredential)
        }
        catch {
            Write-SyncLog -Level "ERROR" -Message $_.Exception.Message
        }

        Start-Sleep -Seconds ($IntervalMinutes * 60)
    }
}

$ResolvedNextcloudCredential = Resolve-SyncCredential `
    -Credential $NextcloudCredential `
    -CredentialPath $NextcloudCredentialPath `
    -PromptMessage "Nextcloud のユーザー名とアプリ パスワードを入力してください。" `
    -Mandatory

$ResolvedSourceCredential = Resolve-SyncCredential `
    -Credential $SourceCredential `
    -CredentialPath $SourceCredentialPath `
    -PromptMessage "AD ファイル共有のユーザー名とパスワードを入力してください。"

if ($Continuous) {
    Start-NextcloudAdFileSyncLoop -ResolvedNextcloudCredential $ResolvedNextcloudCredential -ResolvedSourceCredential $ResolvedSourceCredential
}
else {
    [void](Invoke-NextcloudAdFileSync -ResolvedNextcloudCredential $ResolvedNextcloudCredential -ResolvedSourceCredential $ResolvedSourceCredential)
}
