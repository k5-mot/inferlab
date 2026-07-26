# Nextcloud AD file sync

Windows Server 上の AD 認証付きファイル共有から Nextcloud へ、30 分おきにファイルをコピーするための PowerShell スクリプトです。

Nextcloud への書き込みは WebDAV を使います。Nextcloud の開発者向けドキュメントでは、認証付きファイル操作のベース URL は `/remote.php/dav/files/{user}/...` で、アップロードは `PUT`、フォルダー作成は `MKCOL` を使うとされています。OIDC や 2FA を使う場合は WebDAV クライアント用のアプリ パスワードを使ってください。

## 準備

PowerShell を管理者として開き、Nextcloud の資格情報を保存します。

```powershell
New-Item -ItemType Directory -Path "C:\ProgramData\Inferlab\NextcloudAdSync" -Force
Get-Credential -Message "Nextcloud のユーザー名とアプリ パスワード" |
    Export-Clixml "C:\ProgramData\Inferlab\NextcloudAdSync\nextcloud.credential.xml"
```

タスク実行ユーザーに AD ファイル共有の読み取り権限がある場合は、AD 側の資格情報保存は不要です。別アカウントで共有へ接続する場合だけ保存します。

```powershell
Get-Credential -Message "AD ファイル共有の資格情報" |
    Export-Clixml "C:\ProgramData\Inferlab\NextcloudAdSync\source.credential.xml"
```

## 手動実行

```powershell
.\sync-ad-files-to-nextcloud.ps1 `
    -SourcePath "\\fileserver.example.local\share\documents" `
    -NextcloudBaseUrl "http://nextcloud.example.local:31200" `
    -RemotePath "/AD-Files" `
    -NextcloudCredentialPath "C:\ProgramData\Inferlab\NextcloudAdSync\nextcloud.credential.xml"
```

AD 側も別資格情報で接続する場合は `-SourceCredentialPath` を追加します。

```powershell
.\sync-ad-files-to-nextcloud.ps1 `
    -SourcePath "\\fileserver.example.local\share\documents" `
    -NextcloudBaseUrl "http://nextcloud.example.local:31200" `
    -RemotePath "/AD-Files" `
    -NextcloudCredentialPath "C:\ProgramData\Inferlab\NextcloudAdSync\nextcloud.credential.xml" `
    -SourceCredentialPath "C:\ProgramData\Inferlab\NextcloudAdSync\source.credential.xml"
```

## 30 分おきに登録

資格情報ファイルを作成した Windows ユーザーと同じユーザーでタスクを登録してください。同じユーザーでないと `Export-Clixml` の資格情報を復号できません。

```powershell
.\register-nextcloud-ad-file-sync-task.ps1 `
    -SourcePath "\\fileserver.example.local\share\documents" `
    -NextcloudBaseUrl "http://nextcloud.example.local:31200" `
    -RemotePath "/AD-Files" `
    -NextcloudCredentialPath "C:\ProgramData\Inferlab\NextcloudAdSync\nextcloud.credential.xml" `
    -IntervalMinutes 30 `
    -RunAsUser "EXAMPLE\svc-nextcloud-sync"
```

## 動作

- 同期元配下のフォルダー構造を Nextcloud の `RemotePath` 配下に作成します。
- ファイルが存在しない、サイズが違う、更新日時が違う場合だけアップロードします。
- Nextcloud 側のほうが新しいファイルは既定で上書きせず、ログに `remote-newer` として残します。
- ファイルサーバー側から削除されたファイルは Nextcloud から削除しません。
- 厳密にファイルサーバーを正とする場合は `-OverwriteRemoteNewer` を指定します。
- ログは既定で `C:\ProgramData\Inferlab\NextcloudAdSync\logs` に出力します。

## 参考

- https://docs.nextcloud.com/server/stable/developer_manual/client_apis/WebDAV/basic.html
- https://docs.nextcloud.com/server/latest/user_manual/br/files/access_webdav.html
