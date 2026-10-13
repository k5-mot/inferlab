# 35-affine

AFFiNE、PostgreSQL、Redisと、HTTPS終端を担うCaddyをまとめたknowledge workspace stack。
hostへ公開するのはCaddyのTCP port `33500`だけであり、AFFiNE本体とdata storeは`internal-nw`内に限定する。

## 構成

- `affine`: AFFiNE本体。外向きURLを`https://${PUBLIC_HOST}:33500`として生成する。
- `affine-migration`: AFFiNE起動前にdatabase migrationを実行するone-shot service。
- `affine-postgres`: AFFiNEのmetadataを保存するPostgreSQLとpgvector。
- `affine-redis`: AFFiNEのcacheと一時状態を保持するRedis。
- `affine-caddy`: Caddyのlocal Certificate Authority（CA）で証明書を発行し、AFFiNEへreverse proxyする唯一の公開service。

## 起動手順

`.env`の`AFFINE_DB_PASSWORD`には、URL encodingが不要な十分に長い英数字のpasswordを設定する。

```bash
# AFFiNE profileだけを起動する。
sudo docker compose --env-file .env --profile affine up -d
```

期待結果:

- `affine-migration`が正常終了する。
- `affine-postgres`、`affine-redis`、`affine-caddy`が`healthy`になる。
- `https://${PUBLIC_HOST}:33500`でAFFiNEが応答する。
- AFFiNE、PostgreSQL、Redisのportはhostへ公開されない。

失敗条件:

- migrationが非zeroで終了する。
- `affine-caddy`が`healthy`にならない。
- TCP port `33500`を既存processが使用している。

## CA証明書の信頼

Caddyはlocal CAを使用するため、最初の接続前に利用端末へroot証明書を信頼させる。証明書はCaddyのdata volumeへ永続化される。

```bash
# Caddyのlocal CA証明書を一時fileへ取り出す。
sudo docker compose --env-file .env --profile affine cp affine-caddy:/data/caddy/pki/authorities/local/root.crt /tmp/affine-caddy-root.crt
```

期待結果:

- `/tmp/affine-caddy-root.crt`が作成される。
- 証明書を利用端末のtrust storeへ登録した後、browserが`https://${PUBLIC_HOST}:33500`を安全な接続として扱う。

失敗条件:

- `affine-caddy`が起動しておらず、証明書をcopyできない。
- 接続先hostnameまたはIP addressが`.env`の`PUBLIC_HOST`と一致しない。

## 停止とrollback

```bash
# AFFiNEの永続volumeを残したまま常駐serviceを停止する。
sudo docker compose --env-file .env --profile affine stop affine-caddy affine affine-redis affine-postgres
```

期待結果:

- AFFiNEの常駐serviceが停止する。
- AFFiNE、PostgreSQL、Caddyのnamed volumeは保持される。

失敗条件:

- 対象containerが停止状態にならない。

## References

- [AFFiNE self-host Compose configuration](https://github.com/toeverything/AFFiNE/blob/canary/.docker/selfhost/compose.yml)
- [AFFiNE self-host configuration schema](https://github.com/toeverything/AFFiNE/blob/v0.27.4/.docker/selfhost/schema.json)
- [Caddy Automatic HTTPS](https://caddyserver.com/docs/automatic-https)
- [Caddy `tls` directive](https://caddyserver.com/docs/caddyfile/directives/tls)
- [Caddy `reverse_proxy` directive](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
