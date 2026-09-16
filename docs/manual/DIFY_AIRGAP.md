# Dify Air-gap Setup

Dify 1.16.1をInternetへ接続せずに運用するための資材取得、起動、plugin導入、検証手順。

閉域運用のnetwork境界、認証、plugin固定、LiteLLM連携の現行契約は[OpenSpecの`dify` profile仕様](/specs/profile-dify/spec)を正規本文とする。このmanualは、その契約を満たすための実行手順と失敗時の判定だけを扱う。

## 適用範囲

接続可能な端末で資材を取得し、承認済み経路でair-gap環境へ転送し、閉域設定を検証した後にDifyを起動する。

## 採用plugin

| Plugin | 固定version | 用途 | 選定理由 |
| --- | --- | --- | --- |
| `langgenius/openai_api_compatible` | `0.0.64` | LLM、Embedding、Rerank、STT、TTS | LiteLLMの内部OpenAI-compatible APIを1つのproviderで利用できるため。 |

provider固有pluginは追加しない。別のpluginを採用する変更では、このmanualのみを変更せず、先に`dify` profile仕様と`21-dify/plugins/plugins.lock.json`を更新する。

## 接続可能な端末で資材を取得する

PowerShell、Python 3、pipを導入した端末でrepository rootから実行する。

```powershell
# root stackで使用するcontainer imageを固定tagまたはdigestで取得する。
.\scripts\Download-DockerImages.ps1 -OutputDir /srv

# 署名付きDify pluginを取得する。
.\scripts\Download-Difypkg.ps1 -OutputDir /srv

# script内に固定したPython依存をPython 3.10から3.14の対象platform向けに取得する。
.\scripts\Download-PipPkgs.ps1 -OutputDir /srv

# Dify plugin packageのchecksumを再確認する。
Get-ChildItem /srv/dify/*.difypkg | Get-FileHash -Algorithm SHA256

# plugin依存wheelが取得済みであることを確認する。
Get-ChildItem /srv/pypi/*.whl | Measure-Object
```

期待結果:

- `langgenius-openai_api_compatible-0.0.64.difypkg`のSHA-256が`53c6b590f99ed0a9e8d8dcb435afc3700826fd1ac1493d7e255916fabc6679d2`になる。
- `/srv/dify/SHA256SUMS`とplugin packageが作成される。
- `/srv/pypi/`に依存wheelが作成される。
- Python 3.10、3.11、3.12、3.13、3.14について8 platformのdownloadが試行される。
- `pip download`がsource distributionへfallbackせず完了する。

失敗条件:

- Marketplaceから取得したpackageまたは内包`requirements.txt`のSHA-256がlock fileと一致しない。
- Python 3.12 Linux x86_64向けwheelを1つでも解決できない。
- container image archive、plugin、wheelのいずれかが空である。

## Air-gap環境へ転送する

repository、`.env`、container image、plugin、PyPI wheelを承認済み媒体または閉域転送経路で移送する。

```bash
# Difyと内部PyPIのbind mount元を作成する。
sudo install -d /srv/21-dify/plugins /srv/12-registry/pypi

# 取得したpluginとPython packageをbind mount元へ配置する。
sudo cp -a /srv/dify/. /srv/21-dify/plugins/
sudo cp -a /srv/pypi/. /srv/12-registry/pypi/

# 転送後のDify plugin checksumを検証する。
cd /srv/21-dify/plugins && sha256sum --check SHA256SUMS
```

`/srv/docker/*.tar`のcontainer engineへのloadは環境運用者が実施する。

期待結果:

- すべてのchecksumが`OK`になる。
- `/srv/docker/*.tar`が環境運用者によるimage load用の入力資材として保持される。

失敗条件:

- checksum不一致または不足fileが1つでもある。
- Composeが参照するimageをlocal container engineで解決できない。

checksum検証に失敗した場合は起動へ進まず、接続可能な端末で再取得して承認済み経路から再転送する。

## Dify用secretを設定する

`.env.sample`を複製し、`dify` profile仕様に従って`DIFY_INIT_PASSWORD`とDify関連のsecretを環境固有の値へ変更する。

```bash
# Difyの初期セットアップgateで使う一時passwordを生成する。
openssl rand -base64 24

# Difyの暗号化、DB、plugin daemon、sandbox、object storageに使うsecretを生成する。
openssl rand -hex 32
```

`DIFY_INIT_PASSWORD`は初回セットアップ画面を開くためのpasswordであり、管理者アカウントのpasswordではない。管理者のemail/passwordは次節で別途設定する。

期待結果:

- `.env`の`DIFY_INIT_PASSWORD`が空ではなく、`admin`でもない。
- Dify関連のすべてのsecretが環境固有の値になる。

失敗条件:

- productionの`.env`で`DIFY_INIT_PASSWORD=admin`を使用している。
- `.env.sample`の例示値をproductionで使用している。

## 起動前に閉域設定を検証する

```bash
# Difyの認証分離、外部endpoint除去、plugin lock、全Compose profileを静的検証する。
STACK_NAME=airgap bash tests/verify-init-static.sh

# Dify profileがInternetへ接続せず解決できることを確認する。
STACK_NAME=airgap docker compose --env-file .env --profile dify config --quiet
```

期待結果:

- Marketplace、update service、telemetry、remote template、public DNS、sandbox外部networkを有効にする設定が検出されない。
- plugin daemonが`http://pypiserver:8080/simple/`だけをPython package indexとして使用する。
- plugin署名検証が有効なままになる。

失敗条件:

- `MARKETPLACE_ENABLED=true`、`ENABLE_NETWORK=true`、public DNS、外部Marketplace URLがComposeへ混入している。
- `PIP_MIRROR_AUTO_DETECT=true`または空の`PIP_MIRROR_URL`へ戻っている。
- plugin署名検証が無効である。

## Difyと内部PyPIを起動する

`dify` profileはplugin daemonより先に`pypiserver`を起動する。`pypiserver`はUID/GID `9898`の非root userで本体processを直接起動し、`/srv/12-registry/pypi`はread-onlyでmountされる。package資材の所有権変更や書き込みは行わない。

```bash
# Dify、plugin daemon、内部PyPIと依存serviceを起動する。
sudo docker compose --env-file .env --profile dify up -d --wait

# 内部PyPIとDify serviceがhealthyであることを確認する。
sudo docker compose --env-file .env --profile dify ps pypiserver dify-api dify-web dify-plugin-daemon dify-sandbox dify-nginx

# plugin daemonが外部mirror自動検出を無効化していることを確認する。
sudo docker compose --env-file .env --profile dify exec dify-plugin-daemon sh -c 'test "$PIP_MIRROR_AUTO_DETECT" = false && test "$PIP_MIRROR_URL" = http://pypiserver:8080/simple/'
```

期待結果:

- `pypiserver`とDify主要serviceがhealthyになる。
- sandboxの`ENABLE_NETWORK`が`false`になる。
- plugin daemonの外部mirror probeが発生しない。

失敗条件:

- plugin daemonが`pypi.org`または外部mirrorを名前解決しようとする。
- wheel不足でplugin Python環境の初期化が失敗する。
- DifyがMarketplaceまたはupdate endpointへ接続を試行する。

## 管理者アカウントを作成する

1. `http://${PUBLIC_HOST}:32100/install`を開く。
2. `.env`の`DIFY_INIT_PASSWORD`を入力する。
3. 管理者専用のemail、username、強固なpasswordを設定する。
4. `http://${PUBLIC_HOST}:32100/signin`で管理者アカウントへログインする。
5. 管理画面のmember一覧で作成したアカウントがownerであることを確認する。

期待結果:

- `/install`が完了後に再表示されない。
- ownerアカウントでconsoleへログインできる。
- Dify以外の認証画面へredirectされない。

失敗条件:

- `DIFY_INIT_PASSWORD`とowner passwordを同じ値にしている。
- 初回セットアップ後も未認証で管理画面を開ける。
- owner以外のaccountが初期管理権限を持つ。

## Pluginをlocal fileから導入する

1. Dify consoleの`Plugins`を開く。
2. `Install Plugin`から`Local Package File`を選ぶ。
3. checksum検証済みの`langgenius-openai_api_compatible-0.0.64.difypkg`を選択する。
4. `OpenAI-API-compatible 0.0.64`として署名検証を通過することを確認する。
5. model providerに次の値を設定する。

| 項目 | 値 |
| --- | --- |
| API Base URL | `http://litellm:4000/v1` |
| API Key | `.env`の`LITELLM_MASTER_KEY` |
| Model Name | `10-inference/litellm/config-litellm.yaml`の対象`model_name` |
| Completion mode | LLMは`Chat` |

6. EmbeddingとRerankにも同じ内部hostを設定し、plugin UIがAPI versionを付加するmodel typeで末尾`/v1`が重複しないことを確認する。

期待結果:

- local packageだけでplugin導入が完了する。
- plugin daemon logに外部hostへの接続試行がない。
- LiteLLMの内部APIでcredential検証とmodel呼出しが成功する。

失敗条件:

- Dify Marketplaceからのinstallを要求する。
- plugin署名検証が失敗する。
- `pypi.org`への接続失敗またはPython package不足が出る。

rollbackする場合はDify consoleから対象pluginをuninstallし、監査と再導入に使う`/srv/21-dify/plugins`と`/srv/12-registry/pypi`は保持する。

## References

- [Dify 1.16.1 environment defaults](https://github.com/langgenius/dify/blob/1.16.1/docker/.env.example)
- [Dify plugin local file release and installation](https://docs.dify.ai/en/develop-plugin/publishing/marketplace-listing/release-by-file)
- [Dify Plugin Daemon environment configuration](https://github.com/langgenius/dify-plugin-daemon/blob/main/.env.example)
- [Dify Marketplace OpenAI-API-compatible plugin](https://marketplace.dify.ai/plugin/langgenius/openai_api_compatible)
