# OpenClawのバージョンアップ手順

## 目的

この手順は、現在のDocker Compose構成を維持したままOpenClawを安全に更新するためのrunbookである。対象構成は次のとおり。

- `openclaw-init`がDiscord pluginを`openclaw-data` volumeへ導入する。
- `openclaw`がGatewayを起動する。
- 2つのserviceが同じ公式OpenClaw imageを使用する。
- `openclaw-data` volumeを2つのserviceで共有する。
- [`openclaw/openclaw.json`](openclaw/openclaw.json)を`openclaw.managed.json`へread-onlyでbind mountし、repositoryを設定のauthoritative sourceとする。

OpenClawの公式containerは、同じstate/configをmountした新imageの起動時に安全なstate migrationとplugin convergenceを実行し、安全に完了できない場合はreadyにならず終了する。このため通常の更新では、事前検証後にimageを置き換えてGatewayを起動する。[OpenClaw Docker](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/install/docker.md#upgrading-container-images)

## 更新方針

更新では次の条件をMUSTとする。

1. `openclaw-init`と`openclaw`のimage tagを同一にする。
2. `latest`を使わず、候補versionの`-browser` tagを固定する。
3. Discord pluginのversionを候補coreのrelease cohortへ合わせる。
4. 現行versionで検証済みbackupと停止中volumeのsnapshotを作成する。
5. 候補imageを本番volumeのcloneへ接続し、config、Doctor、SQLite、pluginを検証する。
6. `config validate`または`doctor --post-upgrade`に失敗した候補を本番へ適用しない。
7. stateを変更する処理はGateway停止中に1つずつ実行する。

公式pluginはcore versionとの互換性を持つrelease cohortへ収束する。correction releaseのimage tagにsuffixがある場合も、pluginはbase release cohortを使用する。[OpenClaw Updating](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/install/updating.md#recommended-openclaw-update)

## 現在判明している`2026.8.2`との非互換

`ghcr.io/openclaw/openclaw:2026.8.2-browser`で現行managed configを検証すると、次のkeyが候補schemaに存在せず失敗する。

| Path | 拒否されるkey |
| --- | --- |
| `agents.defaults` | `imageGenerationModel`、`videoGenerationModel`、`musicGenerationModel`、`mediaGenerationAutoProviderFallback` |
| `messages` | `tts` |
| `gateway.controlUi` | `allowInsecureAuth` |
| `mcp.servers.searxng` | `timeout`、`connect_timeout` |
| `plugins` | `bundledDiscovery` |

OpenClawはunknown keyを含む設定をstrictに拒否するため、上記を残したまま`2026.8.2`へ更新してはならない。候補imageの`config schema`とrelease noteを確認し、必要な機能は候補versionが受け付ける設定へ移し、不要なkeyだけを削除する。[OpenClaw Config CLI](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/cli/config.md#config-schema) [OpenClaw Configuration](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/gateway/configuration.md#strict-validation)

`doctor --fix`はunknown keyを削除する場合がある。機能の移行先を判断せずmanaged configを自動修正させてはならない。[OpenClaw Doctor](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/cli/doctor.md#notes)

## 事前準備

以下のコマンドはrepository rootで実行する。例では現行versionから`2026.8.2`への更新を示す。別versionへ更新するときは、候補imageとplugin versionを読み替える。

```bash
# 更新単位を識別するtimestampを設定する。
export OPENCLAW_UPGRADE_ID="$(date +%Y%m%d-%H%M%S)"

# 現行と候補の公式imageを固定する。
export OPENCLAW_CURRENT_IMAGE="ghcr.io/openclaw/openclaw:2026.7.1-2-browser"
export OPENCLAW_CANDIDATE_IMAGE="ghcr.io/openclaw/openclaw:2026.8.2-browser"

# 候補coreへ合わせるDiscord plugin versionを固定する。
export OPENCLAW_CANDIDATE_PLUGIN_VERSION="2026.8.2"

# backupをrepository外のowner専用directoryへ保存する。
export OPENCLAW_BACKUP_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/inferlab/openclaw-backups/${OPENCLAW_UPGRADE_ID}"

# backup directoryをownerだけが参照できるpermissionで作成する。
install -d -m 700 "$OPENCLAW_BACKUP_DIR"

# 候補imageを本番停止前に取得する。
sudo docker pull "$OPENCLAW_CANDIDATE_IMAGE"

# 候補imageのversion、revision、image IDを記録する。
sudo docker image inspect "$OPENCLAW_CANDIDATE_IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}} {{index .Config.Labels "org.opencontainers.image.revision"}} {{.Id}}' | tee "$OPENCLAW_BACKUP_DIR/candidate-image.txt"

# 候補imageに必要なDoctor optionが存在することを確認する。
sudo docker run --rm --entrypoint node "$OPENCLAW_CANDIDATE_IMAGE" dist/index.js doctor --help
```

期待結果:

- pullとimage inspectが成功し、想定したversionとrevisionが記録される。
- `doctor --help`に`--lint`、`--post-upgrade`、`--fix`、`--session-sqlite`が表示される。

失敗条件:

- imageを取得できない、labelのversionが想定と異なる、または必要なDoctor optionが存在しない。
- 失敗した候補では以降の手順へ進まない。

## backupと本番volumeのsnapshot

OpenClawのarchive backupはSQLite online backup APIを使ってcommitted stateを取得し、`--verify`でmanifestとSQLite整合性を検証する。raw SQLite fileを稼働中に直接copyしてはならない。[OpenClaw Backups](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/install/backups.md#full-archives)

```bash
# 現行imageでbackup対象を表示し、想定外のskipがないことを確認する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw run --rm --no-deps --entrypoint node -v "$OPENCLAW_BACKUP_DIR:/backup" openclaw dist/index.js backup create --output /backup --dry-run --json

# 現行imageでfull archiveを作成し、その場で検証する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw run --rm --no-deps --entrypoint node -v "$OPENCLAW_BACKUP_DIR:/backup" openclaw dist/index.js backup create --output /backup --verify --json

# Gatewayを停止し、volumeのbyte-for-byte snapshotに一貫性を持たせる。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw stop openclaw

# 停止済みOpenClaw containerが使用するvolume名を取得する。
export OPENCLAW_CONTAINER_ID="$(sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw ps -a -q openclaw)"

# 対象containerが一意に取得できたことを検証する。
test -n "$OPENCLAW_CONTAINER_ID"

# `/home/node/.openclaw`へmountされたvolume名を取得する。
export OPENCLAW_VOLUME="$(sudo docker inspect "$OPENCLAW_CONTAINER_ID" --format '{{range .Mounts}}{{if eq .Destination "/home/node/.openclaw"}}{{.Name}}{{end}}{{end}}')"

# snapshot対象が空でないことを検証する。
test -n "$OPENCLAW_VOLUME"

# 停止中volumeをowner情報込みのtar archiveへ保存する。
sudo docker run --rm --user 0 --entrypoint tar --mount "type=volume,src=$OPENCLAW_VOLUME,dst=/source,readonly" --mount "type=bind,src=$OPENCLAW_BACKUP_DIR,dst=/backup" "$OPENCLAW_CURRENT_IMAGE" -C /source -cpf /backup/openclaw-data.tar .

# snapshotを読み出せることを検証する。
sudo tar -tf "$OPENCLAW_BACKUP_DIR/openclaw-data.tar" >/dev/null

# backup artifactのchecksumを保存する。
sudo sha256sum "$OPENCLAW_BACKUP_DIR"/* | sudo tee "$OPENCLAW_BACKUP_DIR/SHA256SUMS"

# 候補検証中も現行serviceを利用する場合は現行versionで再起動する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw up -d openclaw
```

期待結果:

- `backup create --verify`がexit code `0`で完了する。
- `openclaw-data.tar`を`tar -tf`で読み出せる。
- `SHA256SUMS`へすべてのbackup artifactが記録される。
- backupにはcredential、auth profile、channel stateが含まれ得るため、owner専用permissionと暗号化された保存先で保護する。[OpenClaw Backup CLI](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/cli/backup.md#notes)

失敗条件:

- backupにskipped assetがある、archive検証に失敗する、対象volume名が空、またはsnapshotを読み出せない。
- いずれかに失敗した場合、更新を開始しない。

## cloneしたvolumeでの候補image preflight

本番volumeへ候補versionのmigrationを先行適用しないよう、停止中snapshotから一時volumeを作る。

```bash
# 候補検証専用volume名を設定する。
export OPENCLAW_PREFLIGHT_VOLUME="openclaw-preflight-${OPENCLAW_UPGRADE_ID}"

# managed configの絶対pathを取得する。
export OPENCLAW_MANAGED_CONFIG="$(realpath 10-inference/openclaw/openclaw.json)"

# 候補検証専用volumeを作成する。
sudo docker volume create "$OPENCLAW_PREFLIGHT_VOLUME"

# 停止中snapshotを候補検証専用volumeへ展開する。
sudo docker run --rm --user 0 --entrypoint tar --mount "type=volume,src=$OPENCLAW_PREFLIGHT_VOLUME,dst=/restore" --mount "type=bind,src=$OPENCLAW_BACKUP_DIR/openclaw-data.tar,dst=/backup/openclaw-data.tar,readonly" "$OPENCLAW_CURRENT_IMAGE" -C /restore -xpf /backup/openclaw-data.tar

# 候補schemaでmanaged configを検証する。
sudo docker run --rm --entrypoint node --mount "type=volume,src=$OPENCLAW_PREFLIGHT_VOLUME,dst=/home/node/.openclaw" --mount "type=bind,src=$OPENCLAW_MANAGED_CONFIG,dst=/home/node/.openclaw/openclaw.managed.json,readonly" -e HOME=/home/node -e OPENCLAW_HOME=/home/node -e OPENCLAW_STATE_DIR=/home/node/.openclaw -e OPENCLAW_CONFIG_PATH=/home/node/.openclaw/openclaw.managed.json "$OPENCLAW_CANDIDATE_IMAGE" dist/index.js config validate --json

# 候補versionのread-only Doctor checkをerror thresholdで実行する。
sudo docker run --rm --entrypoint node --mount "type=volume,src=$OPENCLAW_PREFLIGHT_VOLUME,dst=/home/node/.openclaw" --mount "type=bind,src=$OPENCLAW_MANAGED_CONFIG,dst=/home/node/.openclaw/openclaw.managed.json,readonly" -e HOME=/home/node -e OPENCLAW_HOME=/home/node -e OPENCLAW_STATE_DIR=/home/node/.openclaw -e OPENCLAW_CONFIG_PATH=/home/node/.openclaw/openclaw.managed.json -e OPENCLAW_SERVICE_REPAIR_POLICY=external "$OPENCLAW_CANDIDATE_IMAGE" dist/index.js doctor --lint --all --severity-min error --json

# 候補versionでplugin互換性をread-only検証する。
sudo docker run --rm --entrypoint node --mount "type=volume,src=$OPENCLAW_PREFLIGHT_VOLUME,dst=/home/node/.openclaw" --mount "type=bind,src=$OPENCLAW_MANAGED_CONFIG,dst=/home/node/.openclaw/openclaw.managed.json,readonly" -e HOME=/home/node -e OPENCLAW_HOME=/home/node -e OPENCLAW_STATE_DIR=/home/node/.openclaw -e OPENCLAW_CONFIG_PATH=/home/node/.openclaw/openclaw.managed.json -e OPENCLAW_SERVICE_REPAIR_POLICY=external "$OPENCLAW_CANDIDATE_IMAGE" dist/index.js doctor --post-upgrade --json

# 候補versionでsession SQLite migrationの対象と問題をread-only確認する。
sudo docker run --rm --entrypoint node --mount "type=volume,src=$OPENCLAW_PREFLIGHT_VOLUME,dst=/home/node/.openclaw" --mount "type=bind,src=$OPENCLAW_MANAGED_CONFIG,dst=/home/node/.openclaw/openclaw.managed.json,readonly" -e HOME=/home/node -e OPENCLAW_HOME=/home/node -e OPENCLAW_STATE_DIR=/home/node/.openclaw -e OPENCLAW_CONFIG_PATH=/home/node/.openclaw/openclaw.managed.json -e OPENCLAW_SERVICE_REPAIR_POLICY=external "$OPENCLAW_CANDIDATE_IMAGE" dist/index.js doctor --session-sqlite dry-run --session-sqlite-all-agents --json

# Discord plugin更新の変更予定をclone上で確認する。
sudo docker run --rm --entrypoint node --mount "type=volume,src=$OPENCLAW_PREFLIGHT_VOLUME,dst=/home/node/.openclaw" --mount "type=bind,src=$OPENCLAW_MANAGED_CONFIG,dst=/home/node/.openclaw/openclaw.managed.json,readonly" -e HOME=/home/node -e OPENCLAW_HOME=/home/node -e OPENCLAW_STATE_DIR=/home/node/.openclaw -e OPENCLAW_CONFIG_PATH=/home/node/.openclaw/openclaw.managed.json "$OPENCLAW_CANDIDATE_IMAGE" dist/index.js plugins update "@openclaw/discord@${OPENCLAW_CANDIDATE_PLUGIN_VERSION}" --dry-run
```

`doctor --lint`はread-onlyでconfig/stateを書き換えない。`doctor --post-upgrade`はplugin互換性のerrorがある場合にexit code `1`を返す。[OpenClaw Doctor](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/cli/doctor.md#lint-mode) [OpenClaw Doctor post-upgrade](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/cli/doctor.md#post-upgrade-mode)

期待結果:

- `config validate`が`valid: true`を返す。
- Doctor lintにerrorがない。
- post-upgrade probeにerror-level findingがない。
- SQLite dry-runが対象agentと移行予定を表示し、parseまたはintegrity errorを報告しない。
- Discord plugin updateのdry-runが候補versionを解決する。

失敗条件:

- 1つでもnon-zero exitとなる、configにunknown keyがある、plugin indexが不正、またはSQLite migrationにerrorがある。
- managed configを修正した場合は`config validate`からすべてのpreflightを再実行する。

## 本番への適用

preflightがすべて成功した後、[`docker-compose.yml`](docker-compose.yml)で次の3箇所を同じ変更単位として更新する。

- `openclaw-init.image`
- `openclaw.image`
- `openclaw-init`の`@openclaw/discord@<version>`

`openclaw-init`はDiscord pluginの存在だけを確認し、既存pluginを更新しない。そのため、volumeへ導入済みのpluginはGateway起動前に明示的に更新する。plugin updateはtracked install specを使い、`--dry-run`で事前確認できる。[OpenClaw plugin management](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/plugins/manage-plugins.md#update-plugins)

候補pluginが権限を追加する場合、非対話実行は同意なしに失敗する。差分を確認した上で、必要な場合だけ`plugins update`へ`--accept-capabilities`を追加する。[OpenClaw plugin capability consent](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/plugins/manage-plugins.md#capability-consent)

```bash
# 更新後のCompose定義を検証する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw config --quiet

# Gatewayを停止し、stateを書き込むprocessを排除する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw stop openclaw

# 候補imageを使って本番volumeのDiscord pluginを更新する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw run --rm --no-deps --entrypoint node openclaw dist/index.js plugins update "@openclaw/discord@${OPENCLAW_CANDIDATE_PLUGIN_VERSION}"

# plugin更新後の互換性をGateway停止中に確認する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw run --rm --no-deps --entrypoint node -e OPENCLAW_SERVICE_REPAIR_POLICY=external openclaw dist/index.js doctor --post-upgrade --json

# init serviceを含め、候補versionのGatewayを起動する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw up -d openclaw

# initの終了状態とGatewayのhealthを確認する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw ps -a openclaw-init openclaw

# 起動時migrationとplugin convergenceのlogを確認する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw logs --tail 300 openclaw-init openclaw

# 稼働中Gatewayのversionを確認する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw exec openclaw node dist/index.js --version

# 稼働中Gatewayのhealthを確認する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw exec openclaw node dist/index.js health

# 稼働中GatewayのDiscord pluginを確認する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw exec openclaw node dist/index.js plugins list --json

# Discord channelを実接続で確認する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw exec openclaw node dist/index.js channels status --channel discord --probe
```

期待結果:

- `openclaw-init`がexit code `0`で終了する。
- `openclaw`がhealthyになり、versionが候補versionと一致する。
- Discord pluginがloadedになり、channel probeが成功する。
- config、session history、workspace、credentialが更新前から継続する。

失敗条件:

- init/runtimeのimageまたはversionが一致しない。
- Gatewayがrestart loopになる、readyにならない、plugin互換性errorが出る、またはhistoryが欠落する。
- 失敗時は繰り返し起動せず、次のrepairまたはrollbackへ進む。

## 起動時repairが必要な場合

routine image upgradeはGateway startupのsafe repairへ任せる。startupが同じimageで`doctor --fix`を要求した場合だけ、Gatewayを停止し、backupが存在することを再確認して実行する。[OpenClaw Docker](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/install/docker.md#upgrading-container-images)

managed configはread-onlyであるため、先にrepository側を候補schemaへ適合させて`config validate`を成功させる。`doctor --fix`はstate/SQLite migrationに限定し、service lifecycleはComposeへ任せる。

```bash
# repair前にGatewayを停止する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw stop openclaw

# 同じ候補image、state volume、managed configでsafe repairを実行する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw run --rm --no-deps --entrypoint node -e OPENCLAW_SERVICE_REPAIR_POLICY=external openclaw dist/index.js doctor --fix --non-interactive

# repair後にsession SQLite migrationを検証する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw run --rm --no-deps --entrypoint node -e OPENCLAW_SERVICE_REPAIR_POLICY=external openclaw dist/index.js doctor --session-sqlite validate --session-sqlite-all-agents --json

# repair後のplugin互換性を再検証する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw run --rm --no-deps --entrypoint node -e OPENCLAW_SERVICE_REPAIR_POLICY=external openclaw dist/index.js doctor --post-upgrade --json

# repairが成功した場合だけGatewayを再起動する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw up -d openclaw
```

`doctor --fix`はpersistent fileからSQLiteへのmigration ownerであり、migrationはGateway停止中に実行する。session migrationでは旧JSON/JSONL、temporary SQLite、destination database/WALが同時に存在できる空き容量を確保する。[OpenClaw Doctor SQLite migration](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/cli/doctor.md#session-sqlite-migration)

期待結果:

- repair、SQLite validate、post-upgrade probeがすべてexit code `0`になる。
- 再起動後にGatewayがhealthyになる。

失敗条件:

- read-only managed configへの書き込み要求、SQLite integrity error、plugin compatibility error、またはdisk不足が発生する。
- 失敗時は同じrepairを反復せず、backupを保全してrollbackする。

## rollback

rollbackは最初にcodeとpluginだけを既知の正常versionへ戻し、migrated stateをそのまま利用できるか確認する。state restoreは更新後の変更を失うため、code-only rollbackが失敗した場合だけ実施する。公式手順もcode-only rollbackを先に行い、古いcodeが新schemaを読めない場合に限ってstateを戻す。[OpenClaw Updating rollback](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/install/updating.md#rollback)

### code-only rollback

1. Gatewayを停止する。
2. SQLite migrationをまたぐ場合は、候補versionのCLIでlegacy artifactをrestoreする。
3. `openclaw-init.image`、`openclaw.image`、Discord plugin pinを直前の正常versionへ戻す。
4. Composeを検証する。
5. Discord pluginを正常versionへ戻す。
6. Gatewayを起動してhealthとhistoryを検証する。

SQLite migrationをまたいでfile-backed versionへ戻す場合は、候補versionのCLIがまだ選択されている間に、Gateway停止状態でlegacy artifactをrestoreする。この処理はSQLite dataを削除しないが、migration後にSQLiteだけで作成されたsessionは古いruntimeから参照できない。[OpenClaw session rollback](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/install/updating.md#downgrading-across-the-session-sqlite-migration)

```bash
# rollback作業を始める前にGatewayを停止する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw stop openclaw

# SQLite migrationをまたぐ場合だけ、候補CLIでlegacy session artifactを復元する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw run --rm --no-deps --entrypoint node -e OPENCLAW_SERVICE_REPAIR_POLICY=external openclaw dist/index.js doctor --session-sqlite restore --session-sqlite-all-agents

# 正常versionへ戻したCompose定義を検証する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw config --quiet

# 正常versionのDiscord pluginへ戻す。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw run --rm --no-deps --entrypoint node openclaw dist/index.js plugins update @openclaw/discord@2026.7.1

# 正常versionのinitとGatewayを起動する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw up -d openclaw

# rollback後のservice状態を確認する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw ps -a openclaw-init openclaw

# rollback後のhealthを確認する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw exec openclaw node dist/index.js health
```

期待結果:

- 2つのserviceが同じ正常versionを使う。
- Gatewayがhealthyになり、更新前のsessionとDiscord接続を参照できる。

失敗条件:

- 古いruntimeがconfigまたはdatabase schemaを拒否する、sessionが欠落する、またはpluginがloadできない。
- この場合だけ、更新後stateを別途保全してから停止中volume snapshotをrestoreする。

### volume snapshotからの最終復旧

この処理は現在の`openclaw-data`を更新前snapshotで置き換え、backup後の変更を失う破壊的操作である。対象volume名とarchive checksumを再確認し、Gatewayと一時的なOpenClaw processがすべて停止している場合だけ実施する。

```bash
# Gatewayを停止し、named volumeを使用するOpenClaw processを排除する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw stop openclaw

# restore対象volumeの名前とmountpointを表示し、想定したvolumeだけであることを確認する。
sudo docker volume inspect "$OPENCLAW_VOLUME"

# 保存済みsnapshotのchecksumを検証する。
sudo sha256sum -c "$OPENCLAW_BACKUP_DIR/SHA256SUMS"

# 現在の失敗stateを別archiveへ退避する。
sudo docker run --rm --user 0 --entrypoint tar --mount "type=volume,src=$OPENCLAW_VOLUME,dst=/source,readonly" --mount "type=bind,src=$OPENCLAW_BACKUP_DIR,dst=/backup" "$OPENCLAW_CURRENT_IMAGE" -C /source -cpf /backup/openclaw-data-before-restore.tar .

# 検証したsnapshotで対象volumeの内容だけを置き換える。
sudo docker run --rm --user 0 --entrypoint sh --mount "type=volume,src=$OPENCLAW_VOLUME,dst=/restore" --mount "type=bind,src=$OPENCLAW_BACKUP_DIR/openclaw-data.tar,dst=/backup/openclaw-data.tar,readonly" "$OPENCLAW_CURRENT_IMAGE" -c 'find /restore -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && tar -C /restore -xpf /backup/openclaw-data.tar'

# 正常versionのCompose定義でserviceを起動する。
sudo docker compose --env-file .env -f 10-inference/docker-compose.yml --profile openclaw up -d openclaw
```

期待結果:

- rollback前のstateが`openclaw-data-before-restore.tar`へ保全される。
- 更新前snapshotでGatewayがhealthyになり、更新前のsessionとplugin状態を参照できる。

失敗条件:

- checksum不一致、対象volume名の不一致、archive展開失敗、または復旧後のGateway health失敗。
- checksumまたは対象が一致しない場合は置換commandを実行しない。

## 検証後の後片付け

rollback期間が終わるまではbackup、raw snapshot、OpenClawが保持するmigration originalを削除しない。OpenClawの`update cleanup`はrollback用originalを恒久的に破棄するため、十分な運用確認後にdry-runを確認してから別作業として実施する。[OpenClaw Updating cleanup](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/install/updating.md#retire-update-recovery-data)

一時preflight volumeだけは、本番稼働とrollback確認が完了した後に削除できる。

```bash
# 一時volumeの対象名を表示し、本番volumeでないことを確認する。
sudo docker volume inspect "$OPENCLAW_PREFLIGHT_VOLUME"

# 検証済みの一時preflight volumeだけを削除する。
sudo docker volume rm "$OPENCLAW_PREFLIGHT_VOLUME"
```

期待結果:

- 一時preflight volumeだけが削除される。
- full backupと`openclaw-data.tar`はrollback retention期間中保持される。

失敗条件:

- `$OPENCLAW_PREFLIGHT_VOLUME`が空、または本番volume名と一致する。
- 対象を一意に確認できない場合は削除しない。

## References

- [OpenClaw Docker](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/install/docker.md)
- [OpenClaw Updating](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/install/updating.md)
- [OpenClaw Backups](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/install/backups.md)
- [OpenClaw Backup CLI](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/cli/backup.md)
- [OpenClaw Config CLI](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/cli/config.md)
- [OpenClaw Configuration](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/gateway/configuration.md)
- [OpenClaw Doctor](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/cli/doctor.md)
- [OpenClaw plugin management](https://github.com/openclaw/openclaw/blob/v2026.8.2/docs/plugins/manage-plugins.md)
