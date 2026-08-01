# ダウンロード

`script/download-stack-images.ps1`で、airgap環境へ持ち込むcontainer image archiveとNextcloud OIDC app archiveを取得する手順。

## 前提

- オンライン端末でPowerShell、`crane`、Docker CLIを実行できる。
- repository rootでこの手順を実行する。
- scriptは引数なしで実行する。
- 取得対象platformはscript既定値の`linux/amd64`。
- 再実行すると既存archiveを上書きする。
- 取得済みcontainer image archiveは`images/`へ保存される。
- Nextcloud OIDC app archiveは`30-nextcloud/nextcloud/apps/user_oidc-v8.10.1.tar.gz`へ保存される。
- `30-nextcloud/nextcloud/apps/*.tar.gz`はGit管理対象外で、airgap環境へfileとして持ち込む。

置換する値:

- `<AIRGAP_HOST>`: airgap serverのhost名またはIP。
- `<AIRGAP_USER>`: airgap serverへfile転送できるuser。
- `<AIRGAP_REPO_DIR>`: airgap server上のrepository root path。

## 1. オンライン端末で資材を取得する

```powershell
# script実行時だけPowerShell scriptの実行を許可する。
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# root stackのimage archiveとNextcloud OIDC app archiveを取得する。
.\script\download-stack-images.ps1
```

期待結果:

- `images/*.tar`が作成される。
- `30-nextcloud/nextcloud/apps/user_oidc-v8.10.1.tar.gz`が作成される。
- `user_oidc-v8.10.1.tar.gz`のSHA256検証が成功する。

失敗条件:

- `crane`またはDocker CLIが見つからない。
- container imageの取得に失敗する。
- `user_oidc-v8.10.1.tar.gz`のchecksumが一致しない。

## 2. 取得済み資材を確認する

```powershell
# 取得したcontainer image archiveの件数を確認する。
Get-ChildItem .\images\*.tar | Measure-Object

# Nextcloud OIDC app archiveのchecksumを確認する。
Get-FileHash -Algorithm SHA256 .\30-nextcloud\nextcloud\apps\user_oidc-v8.10.1.tar.gz
```

期待結果:

- `images/`に複数の`.tar` fileがある。
- OIDC app archiveのhashが`49ced1fe192302f4540b869438b6ccb9ca0d69b717b76ed7075a70aa5cf666fd`と一致する。

失敗条件:

- `images/`が空である。
- OIDC app archiveが存在しない、またはhashが一致しない。

## 3. airgap serverへ転送する

```powershell
# container image archiveをairgap serverへ転送する。
scp -r .\images <AIRGAP_USER>@<AIRGAP_HOST>:<AIRGAP_REPO_DIR>/

# Nextcloud OIDC app archiveをairgap serverのbind mount元へ転送する。
scp .\30-nextcloud\nextcloud\apps\user_oidc-v8.10.1.tar.gz <AIRGAP_USER>@<AIRGAP_HOST>:<AIRGAP_REPO_DIR>/30-nextcloud/nextcloud/apps/
```

期待結果:

- airgap server上に`<AIRGAP_REPO_DIR>/images/*.tar`がある。
- airgap server上に`<AIRGAP_REPO_DIR>/30-nextcloud/nextcloud/apps/user_oidc-v8.10.1.tar.gz`がある。

失敗条件:

- `scp`が失敗する。
- 転送先でarchive fileが欠ける。

## 4. airgap serverでcontainer imageをloadする

```bash
# repository rootへ移動する。
cd <AIRGAP_REPO_DIR>

# 取得済みcontainer image archiveをDockerへ読み込む。
for archive in images/*.tar; do sudo docker load -i "$archive"; done
```

期待結果:

- `sudo docker image ls`でstackが参照するimageが表示される。
- `ghcr.io/k5-mot/oikb:latest`も表示される。

失敗条件:

- `sudo docker load`が失敗する。
- `docker compose config`で参照されるimageが不足する。

## 5. airgap serverでNextcloud OIDC app archiveを確認する

```bash
# OIDC app archiveのchecksumを確認する。
sha256sum 30-nextcloud/nextcloud/apps/user_oidc-v8.10.1.tar.gz
```

期待結果:

- hashが`49ced1fe192302f4540b869438b6ccb9ca0d69b717b76ed7075a70aa5cf666fd`と一致する。
- Nextcloud container起動時に`/opt/inferlab/nextcloud-apps/user_oidc-v8.10.1.tar.gz`としてread-only mountされる。

失敗条件:

- OIDC app archiveが存在しない。
- checksumが一致しない。
- Nextcloudの`06-install-user-oidc.sh` hookがonline downloadへfallbackし、airgapで失敗する。

## 6. stackを起動する

```bash
# nextcloud profileとowui profileを含めてstackを起動する。
sudo docker compose --env-file .env --profile common --profile nextcloud --profile owui up -d

# NextcloudとOIKBの状態を確認する。
sudo docker compose --env-file .env --profile nextcloud --profile owui ps nextcloud oikb
```

期待結果:

- `nextcloud`がhealthyになる。
- Nextcloud logで`06-install-user-oidc.sh`が失敗していない。
- `user_oidc` appが有効化される。

失敗条件:

- Nextcloudがunhealthyになる。
- OIDC app archiveが見つからず、hookが外部URLへ接続しようとして失敗する。

## 7. rollback

```bash
# 起動済みstackを停止する。
sudo docker compose --env-file .env --profile common --profile nextcloud --profile owui down
```

期待結果:

- 対象containerが停止する。
- volumeは削除されない。

失敗条件:

- `docker compose down`が非ゼロ終了する。
