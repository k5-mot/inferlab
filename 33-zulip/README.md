# 33-zulip

Zulip、PostgreSQL、Memcached、RabbitMQ、Redisをまとめたchat stack。Keycloak OIDC loginと初期realm/user作成をCompose内で扱う。

## 起動時初期化

Zulip本体は`/data/post-setup.d`を実行する。Composeでは`33-zulip/post-setup.d`をbind mountし、起動後に次の処理を適用する。

| Script | 初期化内容 |
| --- | --- |
| `10-create-default-realm.sh` | 初期組織、初期管理者、theme、fluid layout設定を作成または更新する。 |
| `20-keycloak-ca.sh` | Keycloak HTTPS issuer用の自己署名証明書をcontainerのtrust storeへ追加する。 |

Zulipの初期管理者passwordは、`ZULIP_AUTO_CREATE_ADMIN_PASSWORD`があればその値を使う。未指定の場合は`/data/initial-admin-password`へランダム値を生成する。

## 起動

```bash
# Zulip stackを起動する。
sudo docker compose --env-file .env --profile zulip up -d
```

期待結果:

- `zulip-postgres`、`zulip-rabbitmq`、`zulip-redis`がhealthyになる。
- `zulip`が`https://${PUBLIC_HOST}:33300`で応答する。
- 初期組織と初期管理者が作成される。
- Keycloak OIDC provider設定が有効になる。

失敗条件:

- `post-setup.d`のscriptが失敗し、Zulip containerが再起動を繰り返す。
- Keycloak証明書が信頼されずOIDC discoveryに失敗する。
- 初期管理者password fileを作成できない。

## 操作性調整CSS

ZulipのWeb UIへ、操作性に直結する高さと余白だけを調整するCSSを適用する。`docker-compose.yml`は`/local-static/themes/usability.css`を配信し、nginxの`sub_filter`で通常HTMLの`</head>`直前にCSS linkを追加する。

この方式はZulip本体のtemplateやbundleをforkしないため、image更新時の追従範囲をCSS selectorに限定できる。一方で、ZulipのDOM classが変わるversionでは調整の一部が効かなくなる可能性がある。

## 適用手順

```bash
# Zulip serviceを再作成し、CSS配信とHTML注入設定を反映する。
docker compose --profile zulip up -d zulip
```

期待結果:

- `https://${PUBLIC_HOST}:33300/local-static/themes/usability.css?v=20260802-collapse-divider`がHTTP 200を返す。
- Zulipの通常画面HTMLに`/local-static/themes/usability.css`のstylesheet linkが含まれる。
- sidebarとcontent areaの横余白が最小化される。
- window端と左右sidebarの横余白が最小化される。
- sidebarとcontent areaに薄い水平線が表示される。
- message入力欄の最小高さが標準より広めの1.5倍相当になる。
- view/channel itemとmessage行の高さと余白が使いやすい密度へ調整され、channel配下のtopic itemは標準相当の高さを維持する。
- fluid layout設定により、sidebar折り畳み時もcontent areaがwindow幅へ追従する。
- Zulip applicationとcontainer processのtimezoneが`Asia/Tokyo`になる。
- Zulipのuser default themeは`light`になる。
- ZulipとKeycloak/OIDC providerの連携設定が反映される。

失敗条件:

- Zulip containerが再起動を繰り返す。
- `nginx -t`相当の設定検証で`sub_filter` directiveが不正と表示される。
- 通常画面HTMLにstylesheet linkが追加されない。

## ロールバック手順

```bash
# Zulip service群を停止し、volumeを解放する。
docker compose --profile zulip stop zulip zulip-postgres zulip-memcached zulip-rabbitmq zulip-redis
```

`docker-compose.yml`から`local-static`と`usability-css.conf`のvolume mountを削除し、`33-zulip/local-static/themes/usability.css`と`33-zulip/nginx/app.d/usability-css.conf`を削除する。その後、Zulip関連containerとvolumeを削除してから再作成する。

```bash
# Zulip service群のcontainerを削除する。
docker compose --profile zulip rm -sf zulip zulip-postgres zulip-memcached zulip-rabbitmq zulip-redis

# Zulip service群の永続volumeを削除する。
docker volume rm "${STACK_NAME}_zulip-data" "${STACK_NAME}_zulip-postgres-data" "${STACK_NAME}_zulip-rabbitmq-data" "${STACK_NAME}_zulip-redis-data"
```

```bash
# Zulip serviceを再作成し、CSS注入なしの初期状態へ戻す。
docker compose --profile zulip up -d zulip
```

期待結果:

- 通常画面HTMLから`/local-static/themes/usability.css`のstylesheet linkが消える。
- Zulipの標準UIへ戻り、初期組織と初期管理者が再作成される。
- Zulip applicationとcontainer processのtimezoneは`docker-compose.yml`の設定値で初期化される。

失敗条件:

- `docker volume rm`が`volume is in use`で失敗する。
- `docker compose --profile zulip up -d zulip`後にZulip containerがhealthyにならない。

## 調整方針

- CSSは`33-zulip/local-static/themes/usability.css`だけを編集する。
- 調整対象はwindow端、sidebar、content area、message入力欄、channel/topic item、message行の高さと余白に限定する。
- 配色、font family、button colorはZulip標準を維持する。
- Zulip本体のtemplateや`/home/zulip/prod-static`内の生成bundleは直接変更しない。

## 固定設定

Zulipのuser default themeは`light`、fluid layoutは有効、Keycloak OIDC providerは`prod` realm固定で構成する。

## 確認手順

```bash
# Zulip profileのcontainer状態を確認する。
sudo docker compose --env-file .env --profile zulip ps

# Zulip HTTPS endpointの応答を確認する。
curl -kfsS "https://${PUBLIC_HOST:-localhost}:33300/" >/dev/null

# 自動生成された初期管理者password fileを確認する。
sudo docker compose --env-file .env --profile zulip exec zulip test -s /data/initial-admin-password
```

期待結果:

- `zulip`がhealthyになる。
- 初期管理者password fileが存在する。
- Keycloak OIDC loginが表示される。

失敗条件:

- `zulip` logにrealm作成失敗が出る。
- `curl -kfsS`がTLSまたはHTTPエラーで失敗する。
- 初期管理者password fileが空になる。

## References

- [Zulip Server configuration](https://zulip.readthedocs.io/en/latest/production/settings.html)
- [Zulip HTML and CSS](https://zulip.readthedocs.io/en/10.2/subsystems/html-css.html)
- [nginx ngx_http_sub_module](https://nginx.org/en/docs/http/ngx_http_sub_module.html)
