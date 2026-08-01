# Zulip

## 操作性調整CSS

ZulipのWeb UIへ、操作性に直結する高さと余白だけを調整するCSSを適用する。`docker-compose.yml`は`/local-static/themes/usability.css`を配信し、nginxの`sub_filter`で通常HTMLの`</head>`直前にCSS linkを追加する。

この方式はZulip本体のtemplateやbundleをforkしないため、image更新時の追従範囲をCSS selectorに限定できる。一方で、ZulipのDOM classが変わるversionでは調整の一部が効かなくなる可能性がある。

## 適用手順

```bash
# Zulip serviceを再作成し、CSS配信とHTML注入設定を反映する。
docker compose --profile zulip up -d zulip
```

期待結果:

- `https://${PUBLIC_HOST}:${ZULIP_HTTPS_HOST_PORT:-33300}/local-static/themes/usability.css?v=20260802-collapse-divider`がHTTP 200を返す。
- Zulipの通常画面HTMLに`/local-static/themes/usability.css`のstylesheet linkが含まれる。
- sidebarとcontent areaの横余白が最小化される。
- window端と左右sidebarの横余白が最小化される。
- sidebarとcontent areaに薄い水平線が表示される。
- message入力欄の最小高さが標準より広めの1.5倍相当になる。
- view/channel itemとmessage行の高さと余白が使いやすい密度へ調整され、channel配下のtopic itemは標準相当の高さを維持する。
- `ZULIP_FLUID_LAYOUT_WIDTH=True`により、sidebar折り畳み時もcontent areaがwindow幅へ追従する。
- Zulip applicationとcontainer processのtimezoneが`Asia/Tokyo`になる。
- `ZULIP_DEFAULT_COLOR_SCHEME`でZulipのuser default themeを変更できる。
- `ZULIP_OIDC_*`でZulipとKeycloak/OIDC providerの連携を変更できる。

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
docker volume rm "${COMPOSE_PROJECT_NAME:-inferlab}_zulip-data" "${COMPOSE_PROJECT_NAME:-inferlab}_zulip-postgres-data" "${COMPOSE_PROJECT_NAME:-inferlab}_zulip-rabbitmq-data" "${COMPOSE_PROJECT_NAME:-inferlab}_zulip-redis-data"
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

## 環境変数

`ZULIP_DEFAULT_COLOR_SCHEME`は`auto`、`automatic`、`dark`、`light`、またはZulip内部値の`1`、`2`、`3`を受け付ける。既定値は`light`。`ZULIP_APPLY_DEFAULT_COLOR_SCHEME_TO_EXISTING_USERS=True`の場合、既存の通常userにも同じthemeを反映する。

`ZULIP_FLUID_LAYOUT_WIDTH=True`はZulip標準のfluid layout user settingを有効化する。`ZULIP_APPLY_FLUID_LAYOUT_WIDTH_TO_EXISTING_USERS=True`の場合、既存の通常userにも同じlayout設定を反映する。

Keycloak連携はOIDC設定として扱う。`ZULIP_OIDC_ENABLED=False`でZulip側のOIDC provider定義を空にできる。providerのissuer、client ID、表示名、auto signupは`ZULIP_OIDC_URL`、`ZULIP_OIDC_CLIENT_ID`、`ZULIP_OIDC_DISPLAY_NAME`、`ZULIP_OIDC_AUTO_SIGNUP`で変更する。

## References

- [Zulip Server configuration](https://zulip.readthedocs.io/en/latest/production/settings.html)
- [Zulip HTML and CSS](https://zulip.readthedocs.io/en/10.2/subsystems/html-css.html)
- [nginx ngx_http_sub_module](https://nginx.org/en/docs/http/ngx_http_sub_module.html)
