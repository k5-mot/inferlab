# 10-inference

LiteLLM、TEI、Hermes-Agent、OpenClaw、ZeroClaw、Kokoroをまとめた推論stack。

## 起動時初期化

このstackには、通常のdaemon起動以外に次の初期化処理がある。

| 対象 | 初期化内容 |
| --- | --- |
| `litellm` | `litellm/config-litellm.yaml`を読み込み、TEI、外部provider、Langfuse連携をまとめる。 |
| `hermes-agent` | LiteLLM向けの相関ID header bridgeを有効にしてgatewayを起動する。Langfuseへの送信はLiteLLMに集約する。 |
| `openclaw-init` | OpenClaw公式imageに含まれないDiscord pluginを、初回だけ`openclaw-data` volumeへ導入する。 |
| `openclaw` | `openclaw-init`が永続volumeへ複製したmanaged configを読み込む。Langfuseへの送信はLiteLLMに集約する。 |
| `zeroclaw-init` | `zeroclaw-data` volumeにworkspace directoryを作成し、`zeroclaw/config.toml`の版番号が変わった場合だけ基底設定を配置する。所有者はZeroClawの実行user (uid `65534`) へ合わせる。 |
| `zeroclaw` | 公式imageでdashboardとDiscord channelを起動する。設定は環境変数で注入し、modelをLiteLLMへ向け、Langfuseへの送信はLiteLLMに集約する。 |

## OpenClaw構成

OpenClawは`ghcr.io/openclaw/openclaw`の公式imageを直接使用する。`openclaw-init`はrepository管理の`openclaw/openclaw.json`を、Doctorがschema migrationを書き戻せる`/home/node/.openclaw/openclaw.managed.json`へ複製する。設定のauthoritative sourceはrepositoryとし、Doctorが追加したschema変更はrepository側へ反映する。version更新は[OpenClaw migration manual](../docs/manual/migration/OPENCLAW.md)に従う。

LiteLLM API keyとDiscord bot tokenはOpenClawのSecretRefでprocess environmentから解決する。Discord guild IDとchannel IDはsecretではなくrouting識別子であり、`openclaw/openclaw.json`へ記録する。接続先を変更する場合は、同fileの`channels.discord.guilds`を更新する。

`openclaw-init`は`openclaw-data` volumeのDiscord plugin versionを確認し、OpenClaw coreと同じrelease cohortへinstallまたはupdateする。Docling MCPは専用コンテナを増やさない方針とし、OpenClawとの連携対象に含めない。

```bash
# managed configをOpenClawのschemaで検証する。
sudo docker compose --env-file .env --profile inference --profile openclaw run --rm --no-deps openclaw node dist/index.js config validate

# OpenClaw profileを起動し、初期化serviceを含めて反映する。
sudo docker compose --env-file .env --profile inference --profile openclaw up -d

# Discord pluginの読み込み元と状態を確認する。
sudo docker compose --env-file .env --profile inference --profile openclaw exec openclaw node dist/index.js plugins list

# Discord channelの接続状態を確認する。
sudo docker compose --env-file .env --profile inference --profile openclaw exec openclaw node dist/index.js channels status --channel discord --probe
```

期待結果:

- `config validate`が成功する。
- `openclaw-init`がexit code `0`で終了する。
- `openclaw`がhealthyになる。
- `plugins list`でDiscord pluginがloadedになる。
- Discord channelのprobeが成功する。

失敗条件:

- read-only設定がschema validationに失敗する。
- Discord pluginの導入または読み込みに失敗する。
- Discord channelのprobeが接続に失敗する。
- OpenClawが`http://127.0.0.1:18789/healthz`で応答しない。

## 起動

```bash
# inference stackを起動する。
sudo docker compose --env-file .env --profile inference up -d
```

期待結果:

- `tei-embedding`、`tei-reranking`がhealthyになる。
- `litellm`が`http://${PUBLIC_HOST}:31000/ui`で応答する。
- `zeroclaw`が`http://${PUBLIC_HOST}:31003`で応答する。
- `kokoro`がhealthcheckに成功する。

失敗条件:

- TEIがmemory不足で再起動を繰り返す。
- LiteLLMの設定解決に失敗する。
- Hermes-AgentがOpen WebUIまたはLiteLLMへ接続できない。
- ZeroClawのDiscord bot tokenが不正である。

## ZeroClawの初期設定

ZeroClawは`ghcr.io/zeroclaw-labs/zeroclaw`の公式imageを直接使用し、dashboardを`http://${PUBLIC_HOST}:31003`で公開する。基底設定 (schema、risk profile、runtime profile、memory storage) は`zeroclaw/config.toml`で管理し、provider、channel、peer group、secretは`ZEROCLAW_<dotted path>`形式の環境変数でComposeから注入する。`__`がconfig pathの区切りになる。

ZeroClawはpairing tokenを`config.toml`へ書き戻すため、`zeroclaw-init`は適用済みの版番号を`.inferlab-managed-config`へ記録し、`zeroclaw/config.toml`先頭の版番号が変わった場合だけ置き換える。基底設定を変更した場合は版番号を上げる。版番号を上げるとdashboardの再pairingが必要になる。

dashboardはgatewayのpairingで認証する。初回接続時は、container logに出力されるpairing codeをdashboardへ入力する。

```bash
# ZeroClaw dashboardのpairing codeを確認する。
sudo docker compose --env-file .env --profile zeroclaw logs zeroclaw | grep -i pair
```

モデルはZeroClawからLiteLLMへ集約する。`litellm.default` providerで`google/gemma4:31b`を既定とし、失敗時は`litellm.gptoss` providerの`openai/gpt-oss:20b`へfallbackする。ZeroClawはrate limit時にprovider alias単位でcooldownするため、fallback modelは別aliasとして定義する。

| Model ID | 用途 | 接続先 |
| --- | --- | --- |
| `google/gemma4:31b` | 既定model | `http://litellm:4000/v1` |
| `openai/gpt-oss:20b` | fallback model (`litellm.gptoss`) | `http://litellm:4000/v1` |

providerのAPI keyには`.env`の`LITELLM_MASTER_KEY`を使う。ZeroClaw由来のrequestへ`ZeroClaw` trace名と`zeroclaw` tagを付けるため、LiteLLMの`langfuse_otel` callbackからLangfuse上で識別できる。

Discord channelは`.env`の`ZEROCLAW_DISCORD_BOT_TOKEN`で有効化する。mentionを含むmessageだけに応答し、botからのmessageには応答しない。発言者は`peer_groups.discord`で全員を許可する。発言者を絞る場合は`ZEROCLAW_peer_groups__discord__external_peers`へDiscord user IDを列挙する。

ZeroClawのconfig、memory、session、workspaceは`zeroclaw-data` named volumeへ保存する。人格のauthoritative sourceは次のGit管理fileであり、containerのworkspaceへread-onlyでbind mountする。

| file | 内容 |
| --- | --- |
| `zeroclaw/persona/SOUL.md` | 基本原則、境界、口調 |
| `zeroclaw/persona/IDENTITY.md` | 名前、役割、スタイル |
| `zeroclaw/persona/USER.md` | ユーザープロフィール |
| `zeroclaw/persona/AGENTS.md` | 安全、内部と外部の判断、記憶の扱い |

dashboardから上記fileを編集してもread-only mountには保存できない。人格を変更する場合はrepository側を編集し、ZeroClawを再作成する。`MEMORY.md`はZeroClawが書き込むため、Git管理しない。

```bash
# ZeroClawを再作成し、環境変数の設定と人格fileを反映する。
sudo docker compose --env-file .env --profile zeroclaw up -d --force-recreate zeroclaw-init zeroclaw

# 環境変数で注入された設定を確認する。
sudo docker compose --env-file .env --profile zeroclaw exec zeroclaw zeroclaw config list

# ZeroClawのdaemon、scheduler、channelを診断する。
sudo docker compose --env-file .env --profile zeroclaw exec zeroclaw zeroclaw doctor
```

期待結果:

- `zeroclaw-init`がexit code `0`で完了し、`zeroclaw`が`healthy`になる。
- `http://${PUBLIC_HOST}:31003`でdashboardへpairingできる。
- `config list`で`agents.default.model_provider`が`litellm.default`と表示される。
- Discord botが接続し、mentionを含むmessageへ人格fileに沿った口調で応答する。
- ZeroClawのmodel requestがLiteLLMを経由し、Langfuseへ`zeroclaw` tag付きで記録される。

失敗条件:

- `zeroclaw`が`healthy`にならない、または再起動を繰り返す。
- ZeroClawから`http://litellm:4000/v1`へ接続できない。
- Discord bot tokenを設定してもDiscord gatewayへ接続できない。
- Git管理した人格fileへcontainerから書き込める。

### QwenPawからの移行

QwenPawは2026-11-25にZeroClawへ置き換えた。人格fileは次のように移した。会話履歴とmemoryはQwenPaw独自形式のため移行しない。

| QwenPaw | ZeroClaw |
| --- | --- |
| `qwenpaw/persona/SOUL.md` | `zeroclaw/persona/SOUL.md` |
| `qwenpaw/persona/AGENTS.md` | `zeroclaw/persona/AGENTS.md` |
| `qwenpaw/persona/PROFILE.md`の「アイデンティティ」 | `zeroclaw/persona/IDENTITY.md` |
| `qwenpaw/persona/PROFILE.md`の「ユーザープロフィール」 | `zeroclaw/persona/USER.md` |

`.env`の`QWENPAW_DISCORD_BOT_TOKEN`は`ZEROCLAW_DISCORD_BOT_TOKEN`へ名前を変える。同じbot tokenをQwenPawとZeroClawで同時に使ってはならない (MUST NOT)。両方が同じmessageへ応答する。

旧QwenPawのvolume (`qwenpaw-data`、`qwenpaw-secrets`、`qwenpaw-backups`) はComposeから外れるが自動削除しない。不要と判断した後に削除する。

```bash
# 旧QwenPawのvolumeを削除する。会話履歴とcredentialも削除される。
sudo docker volume rm "${STACK_NAME}_qwenpaw-data" "${STACK_NAME}_qwenpaw-secrets" "${STACK_NAME}_qwenpaw-backups"
```

期待結果:

- 3つのvolumeが削除される。

失敗条件:

- volumeが使用中と表示される。旧QwenPaw containerが残っている場合は先に削除する。

## Langfuse連携

Langfuseへの送信はLiteLLMの`langfuse_otel` callbackに集約する。Hermes-Agent、OpenClaw、ZeroClawはLangfuse SDKやLangfuse pluginから直接送信せず、LiteLLMへのprovider requestへ集約する。

Hermes-Agentは`litellm-langfuse-headers` pluginで、`session_id`、`turn_id`、`sender_id`、`api_request_id`をLiteLLMのLangfuse連携用headerへ変換する。OpenClawとZeroClawはLiteLLM providerの静的headerで、それぞれのtrace、generation名、tagを渡す。

## 確認手順

```bash
# inference profileのcontainer状態を確認する。
sudo docker compose --env-file .env --profile inference ps

# LiteLLMのreadiness endpointを確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:31000/health/readiness" >/dev/null

```

期待結果:

- LiteLLM readinessが成功する。
- TEIのhealthcheckがhealthyになる。
- ZeroClaw dashboardが`http://${PUBLIC_HOST}:31003`で応答する。

失敗条件:

- LiteLLM readinessが5xxまたは接続失敗になる。

## References

- [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw)
- [ZeroClaw Docker & Containers](https://github.com/zeroclaw-labs/zeroclaw/blob/master/docs/book/src/setup/container.md)
- [ZeroClaw Custom Providers](https://github.com/zeroclaw-labs/zeroclaw/blob/master/docs/book/src/providers/custom.md)
- [ZeroClaw Discord](https://github.com/zeroclaw-labs/zeroclaw/blob/master/docs/book/src/channels/discord.md)
- [ZeroClaw Peer Groups](https://github.com/zeroclaw-labs/zeroclaw/blob/master/docs/book/src/channels/peer-groups.md)
- [OpenClaw Docker](https://docs.openclaw.ai/install/docker)
- [OpenClaw Configuration](https://docs.openclaw.ai/gateway/configuration)
- [OpenClaw Discord](https://docs.openclaw.ai/channels/discord)
