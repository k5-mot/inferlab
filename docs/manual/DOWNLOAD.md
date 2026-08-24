# ダウンロード

`script/Download-Images.ps1`、Docling資材取得script、`script/Download-Dify-Plugins.ps1`、`script/Download-Nextcloud-Oidc.ps1`、`script/Download-HuggingFace-Repos.ps1`、package取得script、VSIX取得scriptで、airgap環境へ持ち込む資材を取得する手順。

## 前提

- オンライン端末でPowerShell、`crane`、Docker CLI、Python 3、pip、Node.js、npmを実行できる。
- Docling資材の取得ではDockerまたはWSLを使用せず、PowerShell版は`docling-tools`、Shell版は`docling-tools`、`curl`、`sha256sum`を使用する。
- repository rootでこの手順を実行する。
- scriptは引数なしで実行できる。
- container imageの取得対象platformはscript既定値の`linux/amd64`。
- PyPI packageとnpm packageの取得対象platformはscript既定値のLinux x86_64。
- 再実行すると既存archiveを上書きする。
- Docling資材取得scriptを除く各scriptの既定保存先は、`/srv`配下の資材種別directoryである。
- 取得済みcontainer image archiveは`/srv/oci-archive/`へ保存される。
- Hugging Face repositoryは`/srv/huggingface/<owner>--<repo>/`へ保存される。
- Docling modelとTesseract traineddataは`out/srv/docling/`へ配布先と同じtreeで保存される。
- Nextcloud OIDC app archiveは`/srv/30-nextcloud/apps/`へ保存される。
- Dify pluginは`/srv/21-dify/plugins/`へ保存される。
- PyPI package archiveは`/srv/12-registry/pypi/`へ保存される。
- npm package archiveは`/srv/12-registry/npm-packages/`へ保存される。
- RPM packageは`/srv/12-registry/rpm/`へ保存される。
- deb packageは`/srv/12-registry/deb/`へ保存される。
- VSIX fileは`/srv/12-registry/vsix/`へ保存される。

置換する値:

- `<AIRGAP_HOST>`: airgap serverのhost名またはIP。
- `<AIRGAP_USER>`: airgap serverへfile転送できるuser。
- `<AIRGAP_REPO_DIR>`: airgap server上のrepository root path。

## 1. オンライン端末で資材を取得する

```powershell
# script実行時だけPowerShell scriptの実行を許可する。
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# root stackのimage archiveを取得する。
.\script\Download-Images.ps1 -ImageDirectory /srv/oci-archive

# 署名付きDify pluginとLinux x86_64向け依存wheelを取得する。
.\script\Download-Dify-Plugins.ps1

# Nextcloud OIDC app archiveを取得する。
.\script\Download-Nextcloud-Oidc.ps1

# Hugging Face model repositoryを取得する。
.\script\Download-HuggingFace-Repos.ps1

# Docling modelとTesseract traineddataを取得する。
.\script\Download-Docling-Assets.ps1 -OutputDirectory out

# Linux x86_64向けのPyPI package archiveを取得する。
.\script\Download-Pip-Packages.ps1

# Linux x86_64向けのnpm package archiveを取得する。
.\script\Download-Npm-Packages.ps1

# Linux x86_64向けのRPM packageを取得する。
.\script\Download-Rpm-Packages.ps1

# Linux x86_64向けのdeb packageを取得する。
.\script\Download-Deb-Packages.ps1

# VS Code拡張機能のVSIX fileを取得する。
.\script\Download-Vscode-Extensions.ps1
```

Linux/macOS shellでNextcloud OIDC app archiveだけを取得する場合:

```bash
# Nextcloud OIDC app archiveを/srvへ取得する。
sudo ./script/Download-Nextcloud-Oidc.sh
```

Linux/macOS shellでDocling資材を取得する場合:

```bash
# Docling modelとTesseract traineddataをout/srv/doclingへ取得する。
./script/download-docling-assets.sh --output-directory out
```

期待結果:

- `/srv/oci-archive/*.tar`が作成される。
- `/srv/30-nextcloud/apps/user_oidc-v8.10.1.tar.gz`が作成される。
- `/srv/21-dify/plugins/langgenius-openai_api_compatible-0.0.64.difypkg`が作成され、SHA-256検証が成功する。
- `user_oidc-v8.10.1.tar.gz`のSHA256検証が成功する。
- `/srv/huggingface/`に`owner--repo`形式のmodel repository directoryが作成される。
- `out/srv/docling/`直下にmodel catalog各stageで⭐が付いたmodelがDocling公式CLIで取得される。
- `out/srv/docling/tesseract/`にchecksum検証済みの英語・日本語traineddataが作成される。
- `/srv/12-registry/pypi/*`にpackage archiveが作成される。
- `/srv/12-registry/npm-packages/*.tgz`が作成される。
- `/srv/12-registry/rpm/*.rpm`が作成される。
- `/srv/12-registry/deb/*.deb`が作成される。
- `/srv/12-registry/vsix/*.vsix`が作成される。

失敗条件:

- `crane`またはDocker CLIが見つからない。
- container imageの取得に失敗する。
- `user_oidc-v8.10.1.tar.gz`のchecksumが一致しない。
- Dify plugin、内包requirements、依存wheelの取得またはchecksum検証に失敗する。
- `huggingface-cli`が見つからない、またはmodel repositoryの取得に失敗する。
- `docling-tools`によるmodel取得、traineddataのdownload、またはchecksum検証に失敗する。
- `pip download`が失敗する。
- `npm install`または`npm pack`が失敗する。
- RPM repository metadataまたはpackage fileの取得に失敗する。
- deb repository metadataまたはpackage fileの取得に失敗する。
- Visual Studio MarketplaceからVSIXを取得できない。

## 2. 取得済み資材を確認する

```powershell
# 取得したcontainer image archiveの件数を確認する。
Get-ChildItem /srv/oci-archive/*.tar | Measure-Object

# Nextcloud OIDC app archiveのchecksumを確認する。
Get-FileHash -Algorithm SHA256 /srv/30-nextcloud/apps/user_oidc-v8.10.1.tar.gz

# Dify plugin packageのchecksumを確認する。
Get-FileHash -Algorithm SHA256 /srv/21-dify/plugins/langgenius-openai_api_compatible-0.0.64.difypkg

# 取得したHugging Face repositoryの件数を確認する。
Get-ChildItem /srv/huggingface -Directory | Measure-Object

# 取得したDocling model directoryの件数を確認する。
Get-ChildItem out/srv/docling -Directory | Where-Object Name -ne tesseract | Measure-Object

# 取得したTesseract traineddataのchecksumを確認する。
Get-FileHash -Algorithm SHA256 out/srv/docling/tesseract/*.traineddata

# 取得したPyPI package archiveの件数を確認する。
Get-ChildItem /srv/12-registry/pypi/* | Measure-Object

# 取得したnpm package archiveの件数を確認する。
Get-ChildItem /srv/12-registry/npm-packages/*.tgz | Measure-Object

# 取得したRPM packageの件数を確認する。
Get-ChildItem /srv/12-registry/rpm/*.rpm | Measure-Object

# 取得したdeb packageの件数を確認する。
Get-ChildItem /srv/12-registry/deb/*.deb | Measure-Object

# 取得したVSIX fileの件数を確認する。
Get-ChildItem /srv/12-registry/vsix/*.vsix | Measure-Object
```

期待結果:

- `/srv/oci-archive/`に複数の`.tar` fileがある。
- OIDC app archiveのhashが`49ced1fe192302f4540b869438b6ccb9ca0d69b717b76ed7075a70aa5cf666fd`と一致する。
- Dify plugin packageのhashが`807252fac41666f135fa146001db41adde00eddd8e636154753f548c2daadb86`と一致する。
- Hugging Face repository directoryが存在する。
- Docling model directoryが存在する。
- Tesseract traineddataが存在し、取得script内のSHA-256検証が成功している。
- PyPI package archiveが存在する。
- npm package archiveが存在する。
- RPM packageが存在する。
- deb packageが存在する。
- VSIX fileが存在する。

失敗条件:

- `/srv/oci-archive/`が空である。
- OIDC app archiveが存在しない、またはhashが一致しない。
- Dify plugin packageが存在しない、またはhashが一致しない。
- Hugging Face repository directoryが存在しない。
- Docling model directoryまたはTesseract traineddataが存在しない。
- PyPI package archiveが存在しない。
- npm package archiveが存在しない。
- RPM packageが存在しない。
- deb packageが存在しない。
- VSIX fileが存在しない。

## 3. airgap serverへ転送する

```powershell
# container image archiveをairgap serverのbind mount元へ転送する。
scp -r /srv/oci-archive <AIRGAP_USER>@<AIRGAP_HOST>:/srv/

# Nextcloud OIDC app archiveをairgap serverのbind mount元へ転送する。
scp -r /srv/30-nextcloud <AIRGAP_USER>@<AIRGAP_HOST>:/srv/

# Dify plugin packageとchecksum一覧をairgap serverへ転送する。
scp -r /srv/21-dify <AIRGAP_USER>@<AIRGAP_HOST>:/srv/

# Hugging Face repositoryをairgap serverのbind mount元へ転送する。
scp -r /srv/huggingface <AIRGAP_USER>@<AIRGAP_HOST>:/srv/

# Docling modelとTesseract traineddataをairgap serverのbind mount元へ転送する。
scp -r out/srv/docling <AIRGAP_USER>@<AIRGAP_HOST>:/srv/

# PyPI package archiveをairgap serverのbind mount元へ転送する。
scp -r /srv/12-registry/pypi <AIRGAP_USER>@<AIRGAP_HOST>:/srv/12-registry/

# npm package archiveをairgap serverのbind mount元へ転送する。
scp -r /srv/12-registry/npm-packages <AIRGAP_USER>@<AIRGAP_HOST>:/srv/12-registry/

# RPM packageをairgap serverのbind mount元へ転送する。
scp -r /srv/12-registry/rpm <AIRGAP_USER>@<AIRGAP_HOST>:/srv/12-registry/

# deb packageをairgap serverのbind mount元へ転送する。
scp -r /srv/12-registry/deb <AIRGAP_USER>@<AIRGAP_HOST>:/srv/12-registry/

# VSIX fileをairgap serverのbind mount元へ転送する。
scp -r /srv/12-registry/vsix <AIRGAP_USER>@<AIRGAP_HOST>:/srv/12-registry/
```

期待結果:

- airgap server上に`/srv/oci-archive/*.tar`がある。
- airgap server上に`/srv/30-nextcloud/apps/user_oidc-v8.10.1.tar.gz`がある。
- airgap server上に`/srv/21-dify/plugins/langgenius-openai_api_compatible-0.0.64.difypkg`がある。
- airgap server上に`/srv/huggingface/*`がある。
- airgap server上に`/srv/docling/docling-project--docling-layout-heron/`と`/srv/docling/tesseract/*.traineddata`がある。
- airgap server上に`/srv/12-registry/pypi/*`がある。
- airgap server上に`/srv/12-registry/npm-packages/*.tgz`がある。
- airgap server上に`/srv/12-registry/rpm/*.rpm`がある。
- airgap server上に`/srv/12-registry/deb/*.deb`がある。
- airgap server上に`/srv/12-registry/vsix/*.vsix`がある。

失敗条件:

- `scp`が失敗する。
- 転送先でarchive fileが欠ける。

## 4. airgap serverでcontainer imageをloadする

```bash
# repository rootへ移動する。
cd <AIRGAP_REPO_DIR>

# 取得済みcontainer image archiveをPodmanまたはDockerへ読み込む。
sudo ./script/install-images.sh --image-directory /srv/oci-archive
```

期待結果:

- `sudo docker image ls`または`sudo podman image ls`でstackが参照するimageが表示される。
- OIKB、Hermes-Agent、OpenClawのlocal build imageも表示される。

失敗条件:

- `sudo ./script/install-images.sh`が失敗する。
- `docker compose config`で参照されるimageが不足する。

## 5. airgap serverでDocling資材を確認する

```bash
# Docling modelとTesseract traineddataが存在し、containerから読めるpermissionであることを確認する。
find /srv/docling -maxdepth 2 -type f -readable | head
```

期待結果:

- `/srv/docling/`直下のmodelと`/srv/docling/tesseract/`のfile pathが表示される。
- Compose起動userのUID `1001`から資材を読み取れる。

失敗条件:

- bind mount元のdirectoryまたはfileが存在しない。
- fileに読み取りpermissionがない。

## 6. airgap serverでNextcloud OIDC app archiveを確認する

```bash
# OIDC app archiveのchecksumを確認する。
sha256sum /srv/30-nextcloud/apps/user_oidc-v8.10.1.tar.gz
```

期待結果:

- hashが`49ced1fe192302f4540b869438b6ccb9ca0d69b717b76ed7075a70aa5cf666fd`と一致する。
- Nextcloud本体起動時に`/srv/30-nextcloud/apps/user_oidc-v8.10.1.tar.gz`としてread-only mountされる。

失敗条件:

- OIDC app archiveが存在しない。
- checksumが一致しない。
- Nextcloudの`06-install-user-oidc.sh` hookから`/srv/30-nextcloud/apps/user_oidc-v8.10.1.tar.gz`を参照できない。

## 7. airgap serverでOS packageとVSIXをinstallする

```bash
# RPM系またはdeb系のOS packageをinstallする。
./script/install-system-packages.sh --rpm-directory /srv/12-registry/rpm --deb-directory /srv/12-registry/deb

# VS Code拡張機能をinstallする。
./script/install-vscode-extensions.sh --vsix-directory /srv/12-registry/vsix --editor-command code
```

期待結果:

- rpm系OSでは`tmux`、`nvim`、`vim`、`git`が実行できる。
- deb系OSでは`tmux`、`nvim`、`vim`、`git`が実行できる。
- VS Code互換CLIにVSIX fileがinstallされる。

失敗条件:

- `dnf`、`yum`、`apt-get`のいずれも見つからない。
- local packageの依存関係を解決できない。
- VS Code互換CLIが見つからない、またはVSIX installが失敗する。

## 8. stackを起動する

```bash
# keycloak、nextcloud、owui、rag profileを含めてstackを起動する。
sudo docker compose --env-file .env --profile common --profile keycloak --profile nextcloud --profile owui --profile rag up -d

# NextcloudとOIKBの状態を確認する。
sudo docker compose --env-file .env --profile nextcloud --profile owui ps nextcloud oikb

# bind mount済みmodelを読み込んだDoclingの状態を確認する。
sudo docker compose --env-file .env --profile rag ps docling
```

期待結果:

- `nextcloud`がhealthyになる。
- `docling`が起動時にlocal modelを読み込み、healthyになる。
- Nextcloud logで`06-install-user-oidc.sh`が失敗していない。
- `user_oidc` appが有効化される。

失敗条件:

- Nextcloudがunhealthyになる。
- Docling資材の不足またはpermission違反で`docling`がunhealthyになる。
- OIDC app archiveが見つからず、hookが外部URLへ接続しようとして失敗する。

## 9. rollback

```bash
# 起動済みstackを停止する。
sudo docker compose --env-file .env --profile common --profile keycloak --profile nextcloud --profile owui --profile rag down
```

期待結果:

- 対象containerが停止する。
- volumeは削除されない。

失敗条件:

- `docker compose down`が非ゼロ終了する。

## References

- [Docling model prefetching and offline usage](https://docling-project.github.io/docling/usage/advanced_options/#model-prefetching-and-offline-usage)
- [Docling CLI reference](https://github.com/docling-project/docling/blob/main/docs/reference/cli.md#docling-tools-models)
- [Docling model catalog](https://github.com/docling-project/docling/blob/main/docs/usage/model_catalog.md)
- [Docling Serve](https://github.com/docling-project/docling-serve)
- [Tesseract tessdata_best](https://github.com/tesseract-ocr/tessdata_best)
