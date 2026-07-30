# Registry利用ガイド

利用者端末からInferLabのRPM repository、APT repository、PyPIserver、Verdaccio、Code Marketplaceを使う手順。

## 前提

- Registry serverで`developer` profileの対象serviceが起動している。
- 利用者端末からRegistry serverの各portへ到達できる。
- この手順はpackageの利用者向けで、registryへの資材投入手順は対象外。
- install例のpackage名は、`30-developer/LIST.md`とregistry投入済み資材に合わせて置き換える。

置換する値:

- `<REGISTRY_HOST>`: Registry serverのhost名またはIP。
- `<PYPI_PORT>`: PyPIserverのHTTP port。既定値は`33100`。
- `<NPM_PORT>`: VerdaccioのHTTP port。既定値は`33200`。
- `<CODE_MARKETPLACE_PORT>`: Code MarketplaceのHTTP port。既定値は`33300`。
- `<RPM_PORT>`: RPM repositoryのHTTP port。既定値は`33400`。
- `<DEB_PORT>`: APT repositoryのHTTP port。既定値は`33500`。

## 1. 接続先を確認する

```bash
# PyPIserverのsimple APIへ接続できることを確認する。
curl -fsS "http://<REGISTRY_HOST>:<PYPI_PORT>/simple/" >/dev/null

# Verdaccioへ接続できることを確認する。
curl -fsS "http://<REGISTRY_HOST>:<NPM_PORT>/" >/dev/null

# Code Marketplaceへ接続できることを確認する。
curl -fsS "http://<REGISTRY_HOST>:<CODE_MARKETPLACE_PORT>/healthz" >/dev/null

# RPM repository metadataへ接続できることを確認する。
curl -fsS "http://<REGISTRY_HOST>:<RPM_PORT>/repodata/repomd.xml" >/dev/null

# APT repositoryのRelease fileへ接続できることを確認する。
curl -fsS "http://<REGISTRY_HOST>:<DEB_PORT>/dists/stable/Release" >/dev/null
```

期待結果:

- すべての`curl`が成功する。

失敗条件:

- name resolution、firewall、port公開、またはservice healthの問題で`curl`が失敗する。

## 2. PyPIserverを使う

一時的に使う場合:

```bash
# PyPIserverを参照してPython packageをinstallする。
python -m pip install python-docx pypdf pypandoc --index-url "http://<REGISTRY_HOST>:<PYPI_PORT>/simple/" --trusted-host "<REGISTRY_HOST>"
```

利用者環境の既定値として設定する場合:

```bash
# pipの既定indexをPyPIserverへ変更する。
python -m pip config set global.index-url "http://<REGISTRY_HOST>:<PYPI_PORT>/simple/"

# HTTP接続先をpipのtrusted hostへ追加する。
python -m pip config set global.trusted-host "<REGISTRY_HOST>"

# 設定後のpip参照先を確認する。
python -m pip config list
```

期待結果:

- `pip install`がPyPIserverからpackageを取得する。
- install済みpackageをPythonからimportできる。

失敗条件:

- packageがPyPIserverに存在しない。
- `--trusted-host`または`global.trusted-host`がなく、HTTP repositoryとして拒否される。

rollback:

```bash
# pipの既定index設定を削除する。
python -m pip config unset global.index-url

# pipのtrusted host設定を削除する。
python -m pip config unset global.trusted-host
```

## 3. Verdaccioを使う

一時的に使う場合:

```bash
# Verdaccioを参照してnpm packageをinstallする。
npm install cowsay --registry "http://<REGISTRY_HOST>:<NPM_PORT>/"

# installしたCLI packageを実行できることを確認する。
npx cowsay ok
```

利用者環境の既定値として設定する場合:

```bash
# npmの既定registryをVerdaccioへ変更する。
npm config set registry "http://<REGISTRY_HOST>:<NPM_PORT>/"

# npmのregistry設定を確認する。
npm config get registry

# Verdaccioからpackageをinstallする。
npm install cowsay
```

期待結果:

- `npm install`がVerdaccioからpackageと依存packageを取得する。
- `npx cowsay ok`が実行できる。

失敗条件:

- packageがVerdaccioにpublishされていない。
- npm registry設定が外部registryのままになっている。

rollback:

```bash
# npmのregistry設定を削除して既定値へ戻す。
npm config delete registry
```

## 4. Code Marketplaceを使う

code-serverで使う場合:

```bash
# code-serverのextension marketplace接続先をCode Marketplaceへ変更する。
export EXTENSIONS_GALLERY='{"serviceUrl":"http://<REGISTRY_HOST>:<CODE_MARKETPLACE_PORT>/api","itemUrl":"http://<REGISTRY_HOST>:<CODE_MARKETPLACE_PORT>/item","resourceUrlTemplate":"http://<REGISTRY_HOST>:<CODE_MARKETPLACE_PORT>/files/{publisher}/{name}/{version}/{path}"}'

# Code Marketplace設定を反映してcode-serverを起動する。
code-server
```

VSCodiumで使う場合:

```bash
# VSCodiumのgallery API接続先をCode Marketplaceへ変更する。
export VSCODE_GALLERY_SERVICE_URL="http://<REGISTRY_HOST>:<CODE_MARKETPLACE_PORT>/api"

# VSCodiumのextension item URLをCode Marketplaceへ変更する。
export VSCODE_GALLERY_ITEM_URL="http://<REGISTRY_HOST>:<CODE_MARKETPLACE_PORT>/item"

# VSCodiumを起動する。
codium
```

登録済みextensionをAPIで確認する場合:

```bash
# Code Marketplaceのextension query APIで登録済みVSIXを検索する。
curl -fsS "http://<REGISTRY_HOST>:<CODE_MARKETPLACE_PORT>/api/extensionquery" \
  -H "Accept: application/json;api-version=3.0-preview.1" \
  -H "Content-Type: application/json" \
  --data-raw '{"filters":[{"criteria":[{"filterType":8,"value":"Microsoft.VisualStudio.Code"}],"pageSize":20}],"flags":439}' >/dev/null
```

期待結果:

- code-serverまたはVSCodiumのextension検索がCode Marketplaceを参照する。
- `code-marketplace-importer`が`30-developer/registry/vsix`に配置済みのVSIXを登録し、検索対象になる。

失敗条件:

- Code MarketplaceへHTTP接続できない。
- client側が外部marketplaceを参照している。
- VSIXが`30-developer/registry/vsix`へ配置されていない。
- `code-marketplace-importer`が失敗して、VSIXが`code-marketplace-extensions` volumeへ登録されていない。
- HTTPSが必須のclient構成で、HTTPのCode Marketplaceが拒否される。

rollback:

```bash
# code-server向けのCode Marketplace設定を削除する。
unset EXTENSIONS_GALLERY

# VSCodium向けのCode Marketplace設定を削除する。
unset VSCODE_GALLERY_SERVICE_URL VSCODE_GALLERY_ITEM_URL
```

## 5. RPM repositoryを使う

利用者端末がRHEL互換distributionの場合に使う。

```bash
# InferLab RPM repositoryをdnf/yumへ登録する。
sudo tee /etc/yum.repos.d/inferlab.repo > /dev/null <<'EOF'
[inferlab]
name=InferLab RPM
baseurl=http://<REGISTRY_HOST>:<RPM_PORT>/
enabled=1
gpgcheck=0
EOF

# repository metadataを更新する。
sudo dnf makecache

# RPM packageをinstallする。
sudo dnf install -y tmux vim-enhanced

# installしたcommandを確認する。
tmux -V
```

期待結果:

- `dnf makecache`が`inferlab` repositoryを読む。
- `tmux`と`vim-enhanced`がinstallされる。

失敗条件:

- `repodata/repomd.xml`が見つからない。
- 対象packageまたは依存packageがrepositoryに存在しない。

rollback:

```bash
# InferLab RPM repository設定を削除する。
sudo rm -f /etc/yum.repos.d/inferlab.repo

# repository metadataを更新する。
sudo dnf makecache
```

## 6. APT repositoryを使う

利用者端末がDebian系distributionの場合に使う。

```bash
# InferLab APT repositoryをaptへ登録する。
echo "deb [trusted=yes] http://<REGISTRY_HOST>:<DEB_PORT>/ stable main" | sudo tee /etc/apt/sources.list.d/inferlab.list

# package indexを更新する。
sudo apt-get update

# deb packageをinstallする。
sudo apt-get install -y tmux

# installしたcommandを確認する。
tmux -V
```

期待結果:

- `apt-get update`が`http://<REGISTRY_HOST>:<DEB_PORT>/dists/stable/Release`を読む。
- `tmux`がinstallされる。

失敗条件:

- `dists/stable/Release`が見つからない。
- 対象packageまたは依存packageがrepositoryに存在しない。

rollback:

```bash
# InferLab APT repository設定を削除する。
sudo rm -f /etc/apt/sources.list.d/inferlab.list

# package indexを更新する。
sudo apt-get update
```

## 7. 利用時の切り分け

```bash
# Registry serviceの公開portへTCP接続できることを確認する。
curl -v "http://<REGISTRY_HOST>:<PYPI_PORT>/simple/" 2>&1 | head

# pipが参照している設定を確認する。
python -m pip config list

# npmが参照しているregistryを確認する。
npm config get registry

# Code Marketplaceのhealth endpointへ接続できることを確認する。
curl -v "http://<REGISTRY_HOST>:<CODE_MARKETPLACE_PORT>/healthz" 2>&1 | head

# code-serverが参照するextension marketplace設定を確認する。
printf '%s\n' "$EXTENSIONS_GALLERY"

# VSCodiumが参照するextension marketplace設定を確認する。
printf '%s\n' "$VSCODE_GALLERY_SERVICE_URL"

# dnfに登録済みrepositoryを確認する。
dnf repolist

# aptに登録済みrepository fileを確認する。
cat /etc/apt/sources.list.d/inferlab.list
```

期待結果:

- 利用者端末のpackage managerがInferLab registryを参照している。

失敗条件:

- 利用者端末が外部registryを参照している。
- Registry serverへ接続できない。
