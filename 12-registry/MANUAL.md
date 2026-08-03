# 12-registry MANUAL

この手順は `LIST.md` の資材を取得し、Registry サーバへ初回投入して、利用者が取得できる状態にするための作業メモ。

## 作業場所

| 作業場所 | 用途 |
| --- | --- |
| 資材取得端末 | PowerShell で取得用 script を実行する。 |
| Registry サーバ | Docker Compose と投入用 command を実行する。 |
| 利用者端末 | Registry サーバから package / image / extension / model を取得する。 |

置換する値:

- `<REGISTRY_HOST>`: Registry サーバへ接続する host 名または IP
- `<REGISTRY_USER>`: Registry サーバへ file 転送できる user
- `<REGISTRY_ASSETS>`: Registry サーバ上の取得済み `assets` directory path
- `<NPM_PUBLISH_TOKEN>`: npm publish 用 token

## 1. 資材取得端末: 資材を取得する

```powershell
# script実行時だけPowerShell scriptの実行を許可する。
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# 取得済み資材を置くdirectoryを指定する。
$env:ASSETS_DIR = "assets"

# LIST.mdのPyPI、npm、container image、Hugging Face資材を取得する。
.\12-registry\scripts\download-assets.ps1
```

RPM / deb / VSIX は、取得した file を次の directory へ置く。

```powershell
# RPM fileをpublish対象へ置く。
Copy-Item -Force .\downloaded\*.rpm .\assets\rpm\

# deb fileをpublish対象へ置く。
Copy-Item -Force .\downloaded\*.deb .\assets\deb\

# VSIX fileをpublish対象へ置く。
Copy-Item -Force .\downloaded\*.vsix .\assets\vsix\
```

期待結果: `assets` 配下に投入対象 file が作成される。

失敗基準: script が非ゼロ終了する、または必要な file が作成されない。

## 2. 資材取得端末: 資材を Registry サーバへ転送する

```powershell
# 取得済みassetsをRegistryサーバへ転送する。
scp -r .\assets <REGISTRY_USER>@<REGISTRY_HOST>:<REGISTRY_ASSETS>
```

期待結果: Registry サーバ上の `<REGISTRY_ASSETS>` に `pypi`、`npm`、`docker`、`rpm`、`deb`、`huggingface`、`vsix` がある。

失敗基準: `scp` が失敗する、または転送先で file が欠ける。

## 3. Registry サーバ: registry service を起動する

airgap 環境では、配信 service と publish 用 one-shot service の image を事前に `docker load` するか、内部 registry へ mirror しておく。
rpm metadata 生成には `RPM_PUBLISHER_IMAGE`、deb metadata 生成には `DEB_REPREPRO_IMAGE` で内部 registry 上の image を指定できる。
この構成では `docker compose build` は不要。

```bash
# repository rootへ移動する。
cd /path/to/inferlab

# registry profileの配信serviceと同期serviceを起動する。
sudo docker compose --env-file .env --profile registry up -d docker-registry pypiserver verdaccio code-marketplace rpm-dist deb-dist

# registry serviceの状態を確認する。
sudo docker compose --env-file .env --profile registry ps docker-registry pypiserver verdaccio code-marketplace rpm-dist deb-dist
```

期待結果: `docker-registry`、`pypiserver`、`verdaccio`、`code-marketplace`、`rpm-dist`、`deb-dist` が起動する。

失敗基準: 対象 service が `running` にならない。

## 4. Registry サーバ: package / extension 資材を配置する

`12-registry/registry` 配下へ資材を配置すると、起動済み service が配信または投入を行う。

```bash
# repository rootへ移動する。
cd /path/to/inferlab

# PyPI packageをpypiserverの配信directoryへ配置する。
cp -a <REGISTRY_ASSETS>/assets/pypi/. 12-registry/registry/pypi/

# npm packageをVerdaccio importerの入力directoryへ配置する。
cp -a <REGISTRY_ASSETS>/assets/npm/. 12-registry/registry/npm-packages/

# RPM packageをcreaterepo_cの入力directoryへ配置する。
cp -a <REGISTRY_ASSETS>/assets/rpm/. 12-registry/registry/rpm/

# deb packageをrepreproの入力directoryへ配置する。
cp -a <REGISTRY_ASSETS>/assets/deb/. 12-registry/registry/deb/

# VSIXをcode-marketplace importerの入力directoryへ配置する。
cp -a <REGISTRY_ASSETS>/assets/vsix/. 12-registry/registry/vsix/
```

期待結果: PyPI / npm / RPM / deb / VSIX が各 registry で取得できる。

失敗基準: service logs に投入失敗が出る、または利用者端末から取得できない。

## 5. Registry サーバ: container image を投入する

Docker Registry は `docker.io/library/registry` を使う。`docker save` 形式の archive は `skopeo copy` で投入する。

```bash
# repository rootへ移動する。
cd /path/to/inferlab

# 取得済みcontainer image archiveを配置する。
cp -a <REGISTRY_ASSETS>/assets/docker/. 12-registry/registry/docker-archive/

# hello-world archiveをDocker Registryへ投入する。
skopeo copy --src-tls-verify=false --dest-tls-verify=false docker-archive:12-registry/registry/docker-archive/hello-world_latest.tar docker://<REGISTRY_HOST>:31205/library/hello-world:latest

# ollama archiveをDocker Registryへ投入する。
skopeo copy --src-tls-verify=false --dest-tls-verify=false docker-archive:12-registry/registry/docker-archive/ollama_ollama_latest.tar docker://<REGISTRY_HOST>:31205/library/ollama:latest
```

期待結果: `http://<REGISTRY_HOST>:31205/v2/` が応答し、投入した image を pull できる。

失敗基準: `skopeo copy` が非ゼロ終了する、または Docker Registry から pull できない。

## 6. 利用者端末: PyPI package を使う

```bash
# pypiserverからLIST.mdのpackageをinstallする。
python -m pip install python-docx pypdf pypandoc --index-url http://<REGISTRY_HOST>:31200/simple/ --trusted-host <REGISTRY_HOST>
```

期待結果: `python-docx`、`pypdf`、`pypandoc` を import できる。

失敗基準: `pip install` が失敗する。

## 7. 利用者端末: npm package を使う

```bash
# Verdaccioをnpmの取得先にする。
npm config set registry http://<REGISTRY_HOST>:31201/

# LIST.mdのnpm packageをinstallする。
npm install cowsay

# cowsay CLIを実行できることを確認する。
npx cowsay ok
```

期待結果: `cowsay` と依存 package が `node_modules` に入る。

失敗基準: `npm install` または `npx cowsay ok` が失敗する。

## 8. 利用者端末: container image を使う

```bash
# hello-worldをDocker Registryからpullする。
sudo docker pull <REGISTRY_HOST>:31205/library/hello-world:latest

# ollamaをDocker Registryからpullする。
sudo docker pull <REGISTRY_HOST>:31205/library/ollama:latest
```

期待結果: image を pull できる。

失敗基準: `docker pull` が失敗する。

## 9. 利用者端末: RPM package を使う

```bash
# RPM repositoryをdnfに登録する。
sudo tee /etc/yum.repos.d/inferlab.repo > /dev/null <<'EOF'
[inferlab]
name=InferLab RPM
baseurl=http://<REGISTRY_HOST>:31203/
enabled=1
gpgcheck=0
EOF

# LIST.mdのRPM packageをinstallする。
sudo dnf install -y tmux neovim vim git
```

期待結果: `tmux`、`nvim`、`vim`、`git` を実行できる。

失敗基準: `dnf install` が失敗する。

## 10. 利用者端末: deb package を使う

```bash
# flat deb repositoryをaptに登録する。
echo "deb [trusted=yes] http://<REGISTRY_HOST>:31204/ ./" | sudo tee /etc/apt/sources.list.d/inferlab.list

# aptのpackage情報を更新する。
sudo apt-get update

# LIST.mdのdeb packageをinstallする。
sudo apt-get install -y tmux neovim vim git
```

期待結果: `tmux`、`nvim`、`vim`、`git` を実行できる。

失敗基準: `apt-get install` が失敗する。

## 11. 利用者端末: VSIX を使う

code-server で使う場合は、接続先を code-marketplace に向ける。

```bash
# code-marketplaceを拡張機能marketplaceとして指定する。
export EXTENSIONS_GALLERY='{"serviceUrl":"http://<REGISTRY_HOST>:31202/api","itemUrl":"http://<REGISTRY_HOST>:31202/item","resourceUrlTemplate":"http://<REGISTRY_HOST>:31202/files/{publisher}/{name}/{version}/{path}"}'
```

期待結果: 投入済み VSIX が拡張機能 marketplace から検索できる。

失敗基準: 拡張機能検索が失敗する。

## 12. 利用者端末: Hugging Face model を使う

Hugging Face model は registry service には投入しない。`assets/huggingface` の model directory を利用者端末の任意の場所へ配置して使う。

```bash
# 配置済みmodel directoryを確認する。
find ./huggingface -maxdepth 3 -type f | head
```

期待結果: model file が表示される。

失敗基準: model directory が存在しない。

## References

- [pypiserver](https://github.com/pypiserver/pypiserver)
- [Verdaccio Docker](https://verdaccio.org/docs/docker/)
- [Docker Registry](https://hub.docker.com/_/registry)
- [code-marketplace](https://github.com/coder/code-marketplace)
- [createrepo_c](https://github.com/rpm-software-management/createrepo_c)
- [reprepro](https://salsa.debian.org/debian/reprepro)
