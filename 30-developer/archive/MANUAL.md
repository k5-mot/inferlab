# 30-developer MANUAL

この手順は `LIST.md` の資材を Pulp に登録し、利用者が取得できる状態にするための作業メモ。

## 作業場所

| 作業場所 | 用途 |
| --- | --- |
| 資材取得端末 | `LIST.md` の package / image / model を取得する。 |
| Pulp サーバ | Pulp を起動し、取得済み資材を Pulp に登録する。 |
| 利用者端末 | Pulp から package / image / model を取得する。 |

置換する値:

- `<PULP_IP>`: Pulp に接続する IP
- `<PULP_PASSWORD>`: Pulp の `admin` password
- `<ASSETS_SOURCE>`: Pulp サーバ上で見える取得済み `assets` directory の path
- `<NPM_PACKAGE_JSON>`: 利用者端末で見える npm 用 `package.json` の path

## 前提

Pulp の Docker image には、Pulp 本体、plugin、`pulp` CLI、`hf` CLI が入っている。

`huggingface_hub` 1.x 系では `huggingface-cli` を使わない。Hugging Face の操作は `hf` で実行する。

repository / distribution / remote / namespace は Pulp の DB に保存される設定であり、Docker image には含まれない。そのため、手順 2 は Pulp の DB を新規作成したときだけ実行する。

## 1. Pulp サーバ: Pulp を起動する

```bash
# 資材置場を作成する。
mkdir -p 30-developer/assets/{pypi,npm,docker,rpm,deb,huggingface}

# developer profileのserviceを起動する。
docker compose --env-file .env --profile developer up -d

# Pulp APIの状態を確認する。
curl -fsS http://<PULP_IP>:33000/pulp/api/v3/status/

# Pulp CLIがimage内で使えることを確認する。
docker compose exec -T pulp-api pulp --help

# hf CLIがimage内で使えることを確認する。
docker compose exec -T pulp-api hf --help

# Pulp CLIで疎通確認する。
docker compose exec -T pulp-api pulp --base-url http://pulp-web:8080 --username admin --password '<PULP_PASSWORD>' status
```

期待結果: status API が JSON を返し、`pulp` と `hf` の help が表示される。

失敗基準: `curl` が失敗する、`docker compose ps` で Pulp service が `running` にならない、または `pulp` / `hf` が見つからない。

## 2. Pulp サーバ: 初回だけ repository を作る

すでに作成済みの名前でエラーになった場合は、次のコマンドへ進む。

```bash
# PyPI用repositoryを作る。
docker compose exec -T pulp-api pulp --base-url http://pulp-web:8080 --username admin --password '<PULP_PASSWORD>' python repository create --name python-internal

# PyPI用distributionを作る。
docker compose exec -T pulp-api pulp --base-url http://pulp-web:8080 --username admin --password '<PULP_PASSWORD>' python distribution create --name python-internal --base-path pypi/python-internal --repository python-internal --allow-uploads

# npm用repositoryを作る。
docker compose exec -T pulp-api pulp --base-url http://pulp-web:8080 --username admin --password '<PULP_PASSWORD>' npm repository create --name npm-internal

# npm用distributionを作る。
docker compose exec -T pulp-api pulp --base-url http://pulp-web:8080 --username admin --password '<PULP_PASSWORD>' npm distribution create --name npm-internal --base-path npm/npm-internal --repository npm-internal

# RPM用repositoryを作る。
docker compose exec -T pulp-api pulp --base-url http://pulp-web:8080 --username admin --password '<PULP_PASSWORD>' rpm repository create --name rpm-internal --autopublish

# RPM用distributionを作る。
docker compose exec -T pulp-api pulp --base-url http://pulp-web:8080 --username admin --password '<PULP_PASSWORD>' rpm distribution create --name rpm-internal --base-path rpm-internal --repository rpm-internal --generate-repo-config

# deb用repositoryを作る。
docker compose exec -T pulp-api pulp --base-url http://pulp-web:8080 --username admin --password '<PULP_PASSWORD>' deb repository create --name deb-internal

# deb用distributionを作る。
docker compose exec -T pulp-api pulp --base-url http://pulp-web:8080 --username admin --password '<PULP_PASSWORD>' deb distribution create --name deb-internal --base-path deb-internal --repository deb-internal

# container push用namespaceを作る。
docker compose exec -T pulp-api pulp --base-url http://pulp-web:8080 --username admin --password '<PULP_PASSWORD>' container namespace create --name container-internal

# container用repositoryを作る。
docker compose exec -T pulp-api pulp --base-url http://pulp-web:8080 --username admin --password '<PULP_PASSWORD>' container repository create --name container-internal

# container用distributionを作る。
docker compose exec -T pulp-api pulp --base-url http://pulp-web:8080 --username admin --password '<PULP_PASSWORD>' container distribution create --name container-internal --base-path container-internal --repository container-internal --public
```

Hugging Face は REST API で cache 用 remote と distribution を作る。

```bash
# Hugging Face remoteを作成する。
curl -fsS -u admin:'<PULP_PASSWORD>' -H 'Content-Type: application/json' -X POST http://<PULP_IP>:33000/pulp/api/v3/remotes/hugging_face/hugging-face/ -d '{"name":"hf-remote","url":"https://huggingface.co","policy":"on_demand"}'

# Hugging Face remoteのhrefを取得する。
HF_REMOTE_HREF=$(curl -fsS -u admin:'<PULP_PASSWORD>' http://<PULP_IP>:33000/pulp/api/v3/remotes/hugging_face/hugging-face/?name=hf-remote | jq -r '.results[0].pulp_href')

# Hugging Face distributionを作成する。
curl -fsS -u admin:'<PULP_PASSWORD>' -H 'Content-Type: application/json' -X POST http://<PULP_IP>:33000/pulp/api/v3/distributions/hugging_face/hugging-face/ -d "{\"name\":\"hf-cache\",\"base_path\":\"hf-cache\",\"remote\":\"$HF_REMOTE_HREF\"}"
```

期待結果: 各 repository / distribution が作成される。

失敗基準: `pulp status` に対象 plugin が出ない、または `curl` が `404` を返す。

## 3. 資材取得端末: PyPI 資材を取得する

```powershell
# PyPI資材置場を作成する。
New-Item -ItemType Directory -Force -Path assets/pypi

# LIST.mdのPyPI packageを依存package込みで取得する。
python -m pip download --dest assets/pypi python-docx pypdf pypandoc
```

期待結果: `assets/pypi` に `.whl` または `.tar.gz` が作成される。

失敗基準: `pip download` が失敗する、または取得物が空になる。

## 4. 資材取得端末: npm 資材を取得する

```powershell
# npm資材置場を作成する。
New-Item -ItemType Directory -Force -Path assets/npm

# npm依存解決用の一時directoryを作成する。
New-Item -ItemType Directory -Force -Path work/npm-cowsay

# npm依存解決用の一時directoryへ移動する。
Set-Location work/npm-cowsay

# package-lockを作成する。
npm init -y

# LIST.mdのnpm packageと依存packageをpackage-lockに記録する。
npm install --package-lock-only --ignore-scripts cowsay

# package-lockから依存package込みのpackage.jsonを作る。
node -e "const fs=require('fs'); const lock=require('./package-lock.json'); const deps={}; for (const [k,p] of Object.entries(lock.packages)) { if (!k || !p.resolved || !p.version) continue; deps[k.split('node_modules/').pop()]=p.version; } fs.writeFileSync('../../assets/npm/package.json', JSON.stringify({name:'inferlab-npm-assets',private:true,version:'0.0.0',dependencies:deps}, null, 2)+'\n');"

# npm packageをtgzとして取得する。
node -e "const pkg=require('../../assets/npm/package.json'); for (const [name,version] of Object.entries(pkg.dependencies)) console.log(name+'@'+version)" | ForEach-Object { npm pack $_ --pack-destination ../../assets/npm }

# 作業開始directoryへ戻る。
Set-Location ../..
```

期待結果: `assets/npm` に `cowsay` と依存 package の `.tgz` が作成される。

失敗基準: `npm install` または `npm pack` が失敗する。

## 5. 資材取得端末: container image を取得する

```powershell
# container image資材置場を作成する。
New-Item -ItemType Directory -Force -Path assets/docker

# hello-worldをtarとして取得する。
crane pull docker.io/library/hello-world:latest assets/docker/hello-world_latest.tar

# ollama/ollamaをtarとして取得する。
crane pull docker.io/ollama/ollama:latest assets/docker/ollama_ollama_latest.tar
```

期待結果: `assets/docker` に image tar が作成される。

失敗基準: `crane pull` が失敗する、または tar file が作成されない。

## 6. 資材取得端末: RPM 資材を取得する

```bash
# RPM資材置場を作成する。
mkdir -p assets/rpm

# dnf downloadコマンドを入れる。
sudo dnf install -y dnf-plugins-core

# LIST.mdのRPM packageを依存package込みで取得する。
dnf download --resolve --destdir assets/rpm tmux vim
```

期待結果: `assets/rpm` に `.rpm` が作成される。

失敗基準: `dnf download` が失敗する、または取得物が空になる。

## 7. 資材取得端末: deb 資材を取得する

```bash
# deb資材置場を作成する。
mkdir -p assets/deb

# aptのpackage情報を更新する。
sudo apt-get update

# LIST.mdのdeb packageを依存package込みでdownload cacheへ取得する。
sudo apt-get install --download-only -y tmux

# 取得したdebを資材置場へ集める。
cp /var/cache/apt/archives/*.deb assets/deb/
```

期待結果: `assets/deb` に `.deb` が作成される。

失敗基準: `apt-get` が失敗する、または取得物が空になる。

## 8. 資材取得端末: Hugging Face 資材を取得する

```powershell
# Hugging Face資材置場を作成する。
New-Item -ItemType Directory -Force -Path assets/huggingface/cl-nagoya

# Hugging Face CLIを入れる。
python -m pip install --upgrade "huggingface_hub>=1,<2"

# ruri-v3-310mを取得する。
hf download cl-nagoya/ruri-v3-310m --local-dir assets/huggingface/cl-nagoya/ruri-v3-310m

# ruri-v3-reranker-310mを取得する。
hf download cl-nagoya/ruri-v3-reranker-310m --local-dir assets/huggingface/cl-nagoya/ruri-v3-reranker-310m
```

期待結果: `assets/huggingface` に model file が作成される。

失敗基準: `hf download` が失敗する、または取得物が空になる。

## 9. Pulp サーバ: 取得済み資材を置く

資材取得端末で作った `assets/` directory を、先に Pulp サーバ上の `<ASSETS_SOURCE>` として見える状態にする。

```bash
# Pulpサーバ側の資材置場を作成する。
mkdir -p 30-developer/assets

# 取得済みassetsをPulpサーバ側の資材置場へ同期する。
rsync -a <ASSETS_SOURCE>/ 30-developer/assets/
```

期待結果: `30-developer/assets/` 配下に `pypi`、`npm`、`docker`、`rpm`、`deb`、`huggingface` がある。

失敗基準: 対象 directory が存在しない、または必要な file が欠ける。

## 10. Pulp サーバ: PyPI 資材を登録する

```bash
# PyPI資材をpython-internalへ登録する。
for file in 30-developer/assets/pypi/*; do docker compose run --rm --no-deps -v "$PWD/30-developer/assets:/work/assets:ro" pulp-api pulp --base-url http://pulp-web:8080 --username admin --password '<PULP_PASSWORD>' python content create --repository python-internal --relative-path "$(basename "$file")" --file "/work/assets/pypi/$(basename "$file")"; done
```

期待結果: `python-internal` から PyPI package を取得できる。

失敗基準: `pulp python content create` が失敗する。

## 11. Pulp サーバ: npm 資材を登録する

```bash
# npm資材をnpm-internalへ登録する。
for file in 30-developer/assets/npm/*.tgz; do docker compose run --rm --no-deps -v "$PWD/30-developer/assets:/work/assets:ro" pulp-api pulp --base-url http://pulp-web:8080 --username admin --password '<PULP_PASSWORD>' npm content upload --repository npm-internal --file "/work/assets/npm/$(basename "$file")"; done
```

期待結果: `npm-internal` に npm package の `.tgz` が登録される。

失敗基準: `pulp npm content upload` が失敗する。

## 12. Pulp サーバ: container image を登録する

```bash
# hello-worldのtarをlocal image storeへ読み込む。
podman load -i 30-developer/assets/docker/hello-world_latest.tar

# ollama/ollamaのtarをlocal image storeへ読み込む。
podman load -i 30-developer/assets/docker/ollama_ollama_latest.tar

# Internal Registryへloginする。
podman login --tls-verify=false http://<PULP_IP>:33000 -u admin -p '<PULP_PASSWORD>'

# hello-worldへInternal Registry用tagを付ける。
podman tag docker.io/library/hello-world:latest <PULP_IP>:33000/container-internal/hello-world:latest

# hello-worldをInternal Registryへpushする。
podman push --tls-verify=false <PULP_IP>:33000/container-internal/hello-world:latest

# ollama/ollamaへInternal Registry用tagを付ける。
podman tag docker.io/ollama/ollama:latest <PULP_IP>:33000/container-internal/ollama/ollama:latest

# ollama/ollamaをInternal Registryへpushする。
podman push --tls-verify=false <PULP_IP>:33000/container-internal/ollama/ollama:latest
```

期待結果: Internal Registry から container image を pull できる。

失敗基準: `podman load`、`podman login`、`podman push` のいずれかが失敗する。

## 13. Pulp サーバ: RPM 資材を登録する

```bash
# RPM資材をrpm-internalへ登録してpublishする。
docker compose run --rm --no-deps -v "$PWD/30-developer/assets:/work/assets:ro" pulp-api pulp --base-url http://pulp-web:8080 --username admin --password '<PULP_PASSWORD>' rpm content upload --repository rpm-internal --directory /work/assets/rpm --publish
```

期待結果: `rpm-internal` から RPM package を取得できる。

失敗基準: `pulp rpm content upload` が失敗する。

## 14. Pulp サーバ: deb 資材を登録する

```bash
# deb資材をdeb-internalへ登録する。
for file in 30-developer/assets/deb/*.deb; do docker compose run --rm --no-deps -v "$PWD/30-developer/assets:/work/assets:ro" pulp-api pulp --base-url http://pulp-web:8080 --username admin --password '<PULP_PASSWORD>' deb content upload --repository deb-internal --file "/work/assets/deb/$(basename "$file")" --distribution stable --component main; done

# deb repositoryをsimple modeでpublishする。
docker compose exec -T pulp-api pulp --base-url http://pulp-web:8080 --username admin --password '<PULP_PASSWORD>' deb publication create --repository deb-internal --simple
```

期待結果: `deb-internal` から deb package を取得できる。

失敗基準: `pulp deb content upload` または `pulp deb publication create` が失敗する。

## 15. Pulp サーバ: Hugging Face cache を作る

Hugging Face は `pulp_hugging_face` の pull-through cache として扱う。資材取得端末で取得した model directory は控え用であり、この手順では Pulp への手動 upload には使わない。

```bash
# ruri-v3-310mをPulp経由で取得してcacheを作る。
docker compose exec -T -e HF_ENDPOINT=http://pulp-web:8080/pulp/content/hf-cache pulp-api hf download cl-nagoya/ruri-v3-310m --local-dir /tmp/hf-cache/ruri-v3-310m

# ruri-v3-reranker-310mをPulp経由で取得してcacheを作る。
docker compose exec -T -e HF_ENDPOINT=http://pulp-web:8080/pulp/content/hf-cache pulp-api hf download cl-nagoya/ruri-v3-reranker-310m --local-dir /tmp/hf-cache/ruri-v3-reranker-310m
```

期待結果: 利用者端末から同じ `HF_ENDPOINT` で model を取得できる。

失敗基準: `hf download` が失敗する。

## 16. 利用者端末: PyPI package を使う

```bash
# Internal PyPIからLIST.mdのpackageをinstallする。
python -m pip install python-docx pypdf pypandoc --index-url http://<PULP_IP>:33000/pypi/pypi/python-internal/simple/ --trusted-host <PULP_IP>
```

期待結果: `python-docx`、`pypdf`、`pypandoc` を import できる。

失敗基準: `pip install` が失敗する。

## 17. 利用者端末: npm package を使う

`pulp npm content upload` で登録した package は、`npm install cowsay` のような単体指定では依存 package が入りきらない。そのため、資材取得時に作った `package.json` を使い、依存 package もまとめて指定する。

```bash
# Internal npm registryをnpmの取得先にする。
npm config set registry http://<PULP_IP>:33000/pulp/content/npm/npm-internal/

# package.jsonを作業directoryへ置く。
cp <NPM_PACKAGE_JSON> ./package.json

# LIST.mdのnpm packageと依存packageをまとめてinstallする。
npm install --ignore-scripts

# cowsay CLIを実行できることを確認する。
node node_modules/cowsay/cli.js ok
```

期待結果: `cowsay` と依存 package が `node_modules` に入る。

失敗基準: `npm install` が失敗する、または `node node_modules/cowsay/cli.js ok` が失敗する。

## 18. 利用者端末: container image を使う

```bash
# hello-worldをInternal Registryからpullする。
podman pull --tls-verify=false <PULP_IP>:33000/container-internal/hello-world:latest

# ollama/ollamaをInternal Registryからpullする。
podman pull --tls-verify=false <PULP_IP>:33000/container-internal/ollama/ollama:latest
```

期待結果: `podman images` に対象 image が表示される。

失敗基準: `podman pull` が失敗する。

## 19. 利用者端末: RPM package を使う

```bash
# Internal RPM repositoryをdnfに登録する。
sudo tee /etc/yum.repos.d/inferlab-pulp.repo > /dev/null <<'EOF'
[inferlab-pulp]
name=InferLab Pulp
baseurl=http://<PULP_IP>:33000/pulp/content/rpm-internal/
enabled=1
gpgcheck=0
EOF

# LIST.mdのRPM packageをinstallする。
sudo dnf install -y tmux vim
```

期待結果: `tmux` と `vim` を実行できる。

失敗基準: `dnf install` が失敗する。

## 20. 利用者端末: deb package を使う

```bash
# Internal deb repositoryをaptに登録する。
echo "deb [trusted=yes] http://<PULP_IP>:33000/pulp/content/deb-internal/ stable main" | sudo tee /etc/apt/sources.list.d/inferlab-pulp.list

# aptのpackage情報を更新する。
sudo apt-get update

# LIST.mdのdeb packageをinstallする。
sudo apt-get install -y tmux
```

期待結果: `tmux` を実行できる。

失敗基準: `apt-get install` が失敗する。

## 21. 利用者端末: Hugging Face model を使う

```bash
# Hugging Face CLIの取得先をPulpへ向ける。
export HF_ENDPOINT="http://<PULP_IP>:33000/pulp/content/hf-cache"

# ruri-v3-310mをPulp経由で取得する。
hf download cl-nagoya/ruri-v3-310m

# ruri-v3-reranker-310mをPulp経由で取得する。
hf download cl-nagoya/ruri-v3-reranker-310m
```

期待結果: model file が利用者端末へ取得される。

失敗基準: `hf download` が失敗する。

## References

- [Hugging Face Hub: Migrating to v1.0](https://huggingface.co/docs/huggingface_hub/concepts/migration)
- [Hugging Face Hub: Command Line Interface](https://huggingface.co/docs/huggingface_hub/guides/cli)
- [Pulp Hugging Face: Configuration Options](https://pulpproject.org/pulp_hugging_face/docs/user/guides/configuration/)
- [Pulp Hugging Face: Getting Started with Pull-through Caching](https://pulpproject.org/pulp_hugging_face/docs/user/tutorials/getting_started/)
