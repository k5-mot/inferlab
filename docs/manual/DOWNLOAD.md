# ダウンロード

air-gap環境へ持ち込む資材は、`scripts/README.md`に定義されたPowerShell scriptでオンライン端末へ事前取得する。

## 前提

- repository rootでPowerShell 7を実行できる。
- `crane`、Python 3、pip、Node.js、npm、`hf`を実行できる。
- オンライン端末から各scriptの`$Registries`に定義された取得元へ接続できる。
- container imageの取得対象platformは`linux/amd64`である。
- PyPI packageはPython 3.12から3.15と、scriptに定義された8 platformの組み合わせを対象にする。

取得元または対象packageを変更する場合は、各script先頭の`$Registries`配列と`$Packages`配列を編集する。公開引数は`OutputDir`、from-Project系だけで使用する`ProjectDir`、`Help`に限定される。

置換する値:

- `<AIRGAP_HOST>`: air-gap serverのhost名またはIP。
- `<AIRGAP_USER>`: air-gap serverへfile転送できるuser。
- `<AIRGAP_REPO_DIR>`: air-gap server上のrepository root path。

## 1. オンライン端末で資材を取得する

```powershell
# scriptごとの出力directoryを作成する共通の親directoryを指定する。
$OutputDir = "/srv"

# repositoryに必要な全download scriptを定義する。
$DownloadScripts = @(
    "Download-Difypkg.ps1",
    "Download-Nextcloud.ps1",
    "Download-Docling.ps1",
    "Download-HFRepo.ps1",
    "Download-RPM.ps1",
    "Download-DEB.ps1",
    "Download-VSIX.ps1",
    "Download-DockerImages.ps1",
    "Download-LibreTranslate.ps1",
    "Download-PipPkgs.ps1",
    "Download-NpmPkgs.ps1"
)

# repository rootから全download scriptを順に実行する。
foreach ($Script in $DownloadScripts) {
    pwsh -NoProfile -File (Join-Path "./scripts" $Script) -OutputDir $OutputDir
}
```

期待結果:

- `/srv/`配下に`dify`、`nextcloud`、`docling`、`libretranslate`、`hfrepo`、`rpm`、`deb`、`vscode`、`docker`、`pypi`、`npm`が作成される。
- Dify plugin、Nextcloud app、Tesseract traineddataのchecksum検証が成功する。
- PyPI packageの対象versionとplatformについて、wheelまたは利用可能なsource archiveが取得される。
- Composeが参照するregistry imageが`docker/*.tar`として保存される。

失敗条件:

- 必須commandが見つからない。
- package、model、extensionまたはimageを取得できない。
- checksumが一致しない。
- 対象Python versionで利用できるpackage archiveがない。

### Compose imageだけをcraneで取得する

root Composeから全profileのimage参照を取得するため、削除済みstackや重複imageを手作業で管理する必要はない。次の手順はimageをDocker互換tarballとして`/srv/docker`へ保存する。非公開registryを使用する場合は、実行前に対象registryへ`crane auth login`で認証する。

```powershell
# root Composeを評価して全profile名を取得する。
$Profiles = & docker compose --env-file .env config --profiles
if ($LASTEXITCODE -ne 0) {
    throw "Compose profileの取得に失敗しました。"
}

# 全profileをComposeへ明示する引数を組み立てる。
$ProfileArguments = foreach ($Profile in $Profiles) {
    "--profile"
    $Profile
}

# 削除済みstackを除くroot Composeのimage参照を重複なしで取得する。
$Images = & docker compose --env-file .env @ProfileArguments config --images |
    Sort-Object -Unique
if (($LASTEXITCODE -ne 0) -or ($Images.Count -eq 0)) {
    throw "Compose imageの取得に失敗しました。"
}

# image archiveと取得元一覧の保存directoryを作成する。
$DockerOutputDirectory = "/srv/docker"
New-Item -ItemType Directory -Path $DockerOutputDirectory -Force | Out-Null

# 復元時に元のimage参照を確認できるよう一覧を保存する。
$Images | Set-Content -Path (Join-Path $DockerOutputDirectory "images.txt")

# linux/amd64向けimageをDocker互換tarballとして1件ずつ取得する。
foreach ($Image in $Images) {
    $ArchiveName = ($Image -replace "[/:@]", "_") + ".tar"
    $ArchivePath = Join-Path $DockerOutputDirectory $ArchiveName
    & crane pull --platform linux/amd64 --format tarball $Image $ArchivePath
    if ($LASTEXITCODE -ne 0) {
        throw "imageの取得に失敗しました: $Image"
    }
}
```

期待結果:

- `images.txt`にroot Composeが参照する一意なimage参照が記録される。
- `images.txt`の各imageに対応する`.tar`が`/srv/docker`へ保存される。
- 削除済みstackのimageはroot Composeから除外されるため、取得対象へ含まれない。

失敗条件:

- `.env`が不足し、root Composeを解決できない。
- `docker compose config --profiles`または`docker compose config --images`が非0で終了する。
- registryの認証またはimage取得に失敗し、`crane pull`が非0で終了する。

再実行する場合は同名`.tar`が上書きされる。取得を中止して元へ戻す場合は、専用staging先である`/srv/docker`の未完成`.tar`だけを削除し、`images.txt`を基準に再取得する。

## 2. 取得済み資材を確認する

```powershell
# Dify pluginのchecksum一覧を検証する。
Push-Location /srv/dify
Get-Content SHA256SUMS | ForEach-Object {
    $Hash, $FileName = $_ -split "\s+", 2
    if ((Get-FileHash -Algorithm SHA256 $FileName).Hash.ToLowerInvariant() -ne $Hash) {
        throw "checksum mismatch: $FileName"
    }
}
Pop-Location

# 種別ごとの資材件数を表示する。
$AssetDirectories = @("dify", "nextcloud", "docling", "libretranslate", "hfrepo", "rpm", "deb", "vscode", "docker", "pypi", "npm")
$AssetDirectories |
    ForEach-Object {
        $Directory = Get-Item (Join-Path "/srv" $_)
        [pscustomobject]@{
            Directory = $Directory.Name
            Files = (Get-ChildItem $Directory.FullName -File -Recurse).Count
        }
    }
```

期待結果:

- checksum検証がerrorなく完了する。
- 11個の出力directoryが存在し、各directoryのfile件数が1以上になる。

失敗条件:

- checksum不一致がある。
- 出力directoryまたは取得資材が不足する。

## 3. air-gap serverへ転送する

```powershell
# OutputDir直下の取得資材を承認済みの閉域転送経路でair-gap serverへ転送する。
scp -r /srv/dify /srv/nextcloud /srv/docling /srv/libretranslate /srv/hfrepo /srv/rpm /srv/deb /srv/vscode /srv/docker /srv/pypi /srv/npm <AIRGAP_USER>@<AIRGAP_HOST>:/srv/
```

期待結果:

- air-gap server上の`/srv/`直下に種別ごとの取得済み資材がある。

失敗条件:

- `scp`が非0で終了する。
- 転送元と転送先のfile件数またはchecksumが一致しない。

## 4. 配信先へ資材を配置する

```bash
# 取得資材を配置するservice別directoryを作成する。
sudo install -d /srv/21-dify/plugins /srv/30-nextcloud/apps /srv/huggingface
sudo install -d /srv/12-registry/pypi /srv/12-registry/rpm /srv/12-registry/deb /srv/12-registry/vsix

# Dify、Nextcloud、Hugging Faceの資材をservice別directoryへ配置する。
sudo cp -a /srv/dify/. /srv/21-dify/plugins/
sudo cp -a /srv/nextcloud/. /srv/30-nextcloud/apps/
sudo cp -a /srv/hfrepo/. /srv/huggingface/

# package registryとVS Code Marketplaceの投入元へ資材を配置する。
sudo cp -a /srv/pypi/. /srv/12-registry/pypi/
sudo cp -a /srv/rpm/. /srv/12-registry/rpm/
sudo cp -a /srv/deb/. /srv/12-registry/deb/
sudo cp -a /srv/vscode/. /srv/12-registry/vsix/
```

`/srv/docling`と`/srv/libretranslate`は各serviceがbind mountする取得先をそのまま使用する。`/srv/npm/*.tgz`も配置変更せず、Verdaccioの`npm-importer`からread-onlyで参照する。`/srv/docker/*.tar`のcontainer engineへのloadは環境運用者が実施する。

期待結果:

- 各serviceのbind mount元に必要な資材が配置される。
- `/srv/libretranslate`に英語・日本語のArgos Translate modelとMiniSBD modelが配置される。
- `/srv/npm`がnpm packageの共通bind mount元として保持される。
- `/srv/docker/*.tar`が環境運用者によるimage load用の入力資材として保持される。

失敗条件:

- copyが非0で終了する。
- 配置先に不足fileがある。

## 5. OS packageとVSIXをinstallする

```bash
# RPM系またはdeb系のOS packageをlocal fileだけからinstallする。
sudo ./scripts/install-system-packages.sh --rpm-directory /srv/12-registry/rpm --deb-directory /srv/12-registry/deb

# VS Code互換editorへ取得済みVSIXをinstallする。
./scripts/install-vscode-extensions.sh --vsix-directory /srv/12-registry/vsix --editor-command code
```

期待結果:

- 対象OSで指定packageを実行できる。
- VS Code互換editorに対象extensionが表示される。

失敗条件:

- local packageだけでは依存関係を解決できない。
- editor CLIまたはVSIX installが失敗する。

## 6. rollback

取得済みstaging資材は監査と再配置に利用できるため、service停止時に削除しない。配置した資材を戻す必要がある場合は、事前backupから対象directory単位で復元する。

```bash
# 起動済みstackを停止し、named volumeと取得済み資材を保持する。
cd <AIRGAP_REPO_DIR> && sudo docker compose --env-file .env down
```

期待結果:

- 対象containerが停止し、取得済み資材は残る。

失敗条件:

- `docker compose down`が非0で終了する。

## References

- [go-containerregistry: crane](https://github.com/google/go-containerregistry/blob/main/cmd/crane/doc/crane.md)
- [go-containerregistry: crane pull](https://github.com/google/go-containerregistry/blob/main/cmd/crane/doc/crane_pull.md)
- [go-containerregistry: crane auth login](https://github.com/google/go-containerregistry/blob/main/cmd/crane/doc/crane_auth_login.md)
