# 30-developer

Pulp 3 を使って、開発者向けの社内リポジトリマネージャーを提供する。対象は container / npm / pip / Hugging Face / rpm / deb とする。

## 方針

- `33-registry` は廃止し、開発者向けサービスとして `30-developer` に統合する。
- Pulp 3 は package repository manager として使い、Git forge や CI はこのディレクトリの対象外にする。
- ドメイン名は使わず、`PUBLIC_HOST` に IP アドレスを設定して運用する。
- Web/API/Content は同じ IP と port で公開する。
- 管理 API、同期、アップロード、publish、repository 作成は Keycloak 認証必須にする。
- パッケージ取得は、公開用 distribution では未認証 read を許可する。制限配布が必要な repository だけ RBAC Content Guard を付ける。
- 初期構築は Pulp の REST API と `pulp-cli` で自動化し、Pulp UI は補助的な確認用途に留める。

## ライセンスと社内利用

Pulp は GPLv2+ の OSS で、公式説明でも free and open-source とされている。社内利用の repository manager として無償利用できる候補である。

注意点:

- Pulp 本体と各 plugin のライセンスを配布形態に照らして確認する。
- container image をカスタム build する場合、追加する plugin と依存パッケージのライセンスも確認する。
- Pulp 自体には Nexus Pro のような商用機能境界はないが、plugin ごとに成熟度と運用手順が異なる。

## 対象 plugin

| 用途 | Pulp plugin | 状態 | 備考 |
| --- | --- | --- | --- |
| container / OCI | `pulp_container` | 採用 | Docker/OCI registry API、pull-through caching、push に対応する。 |
| pip / PyPI | `pulp_python` | 採用 | PyPI mirror、upload、pip install 用 distribution に対応する。 |
| rpm | `pulp_rpm` | 採用 | yum/dnf repository の sync、upload、publish に対応する。 |
| deb | `pulp_deb` | 採用 | apt repository の sync、upload、publish に対応する。 |
| npm | `pulp_npm` | 採用、要検証 | sync、publish/host、pull-through cache の公式 docs がある。公式 stable image に含まれない場合はカスタム image に追加する。 |
| Hugging Face | `pulp_hugging_face` | 採用、要検証 | pull-through caching と HF CLI 利用の docs がある。若い plugin なので、本番前に対象モデル形式と認証付き upstream を検証する。 |

公式 `pulp-minimal:stable` は `pulp_container`, `pulp_deb`, `pulp_python`, `pulp_rpm` などを含むが、npm と Hugging Face は含まれない可能性がある。この構成では、`k5-mot/pulp-custom` で build した `ghcr.io/k5-mot/pulp-minimal` と `ghcr.io/k5-mot/pulp-web` を使い、必要 plugin を含む image を pull する。

## 想定する構成

まずは単一ホストの Docker Compose で構築する。Pulp 公式の multi-process image は評価には簡単だが、運用では API / content / worker / DB / Redis / web を分けた compose 構成にする。

想定サービス:

- `pulp-web`: 外部公開 endpoint。API と content を同一 port で提供する。
- `pulp-api`: REST API と browsable API。
- `pulp-content`: package download / registry content 配信。
- `pulp-worker`: sync、upload、publish などの非同期 task。
- `pulp-postgres`: Pulp metadata。
- `pulp-redis`: task/cache。
- `pulp-keycloak-proxy`: Keycloak OIDC 認証を Pulp に渡す reverse proxy。実装時に oauth2-proxy または nginx + auth_request を選定する。

想定 port:

| 用途 | Host port | URL |
| --- | --- | --- |
| Pulp Web/API/Content | `33000` | `http://<IP>:33000/` |
| Keycloak HTTP | `30001` | `http://<IP>:30001/` |
| Keycloak HTTPS | `30002` | `https://<IP>:30002/` |

IP アドレス運用では、Pulp の base URL と Keycloak redirect URI に同じ IP を使う。

```text
PULP_CONTENT_ORIGIN=http://<IP>:33000
PULP_API_ROOT=http://<IP>:33000/pulp/api/v3/
Keycloak redirect URI=http://<IP>:33000/*
```

HTTPS が必要な場合は、IP Subject Alternative Name を含む証明書を発行する。IP SAN のない証明書を使うと、CLI や browser の OIDC flow で検証エラーが起きる。

## Keycloak 連携

Pulp は Keycloak 連携の公式手順を持つ。構成は次のどちらかにする。

### 方式 A: Pulp の python-social-auth 連携 ⇒ 採用

Pulp image に次の Python module を追加する。

- `social-auth-core`
- `social-auth-app-django`

Pulp settings に Keycloak backend を追加する。実装時は既存の Pulp settings に merge する。

```python
INSTALLED_APPS = (
    ...,
    "social_django",
)

AUTHENTICATION_BACKENDS = [
    "social_core.backends.keycloak.KeycloakOAuth2",
    "pulpcore.backends.ObjectRolePermissionBackend",
]
```

Keycloak 側:

- Realm: `${STACK_NAME:-inferlab}`
- Client ID: `pulp`
- Client type: confidential
- Valid redirect URIs: `http://<IP>:33000/*`
- Web origins: `http://<IP>:33000`
- Mapper: `username`, `email`, `groups`, `given name`, `family name`
- Audience mapper: `pulp`

Pulp 側:

- `SOCIAL_AUTH_KEYCLOAK_KEY=pulp`
- `SOCIAL_AUTH_KEYCLOAK_SECRET=<client-secret>`
- `SOCIAL_AUTH_KEYCLOAK_PUBLIC_KEY=<realm-public-key>`
- `SOCIAL_AUTH_KEYCLOAK_AUTHORIZATION_URL=http://<IP>:30001/realms/<realm>/protocol/openid-connect/auth/`
- `SOCIAL_AUTH_KEYCLOAK_ACCESS_TOKEN_URL=http://<IP>:30001/realms/<realm>/protocol/openid-connect/token/`

この方式は Pulp の Django 認証として自然だが、Pulp image の settings と plugin 依存をきちんと管理する必要がある。

### 方式 B: reverse proxy 認証

Keycloak 認証を proxy 側で完了し、Pulp には `REMOTE_USER` 相当の header を渡す。Pulp は `PulpRemoteUserAuthentication` を使う。

```python
REMOTE_USER_ENVIRON_NAME = "HTTP_REMOTE_USER"

AUTHENTICATION_BACKENDS = [
    "pulpcore.app.authentication.PulpNoCreateRemoteUserBackend",
    "pulpcore.backends.ObjectRolePermissionBackend",
]

REST_FRAMEWORK__DEFAULT_AUTHENTICATION_CLASSES = (
    "rest_framework.authentication.SessionAuthentication",
    "pulpcore.app.authentication.PulpRemoteUserAuthentication",
)
```

この方式は Web/API の入口制御をしやすい。一方で、proxy が認証済みユーザー名 header を偽装されないよう、Pulp API を proxy 経由以外から到達不可にする必要がある。

## 認可設計

Keycloak group を Pulp group / role に対応させる。

| Keycloak group | Pulp role | 用途 |
| --- | --- | --- |
| `developer-admins` | admin 相当 | Pulp 全体管理。 |
| `repo-managers` | repository 作成、remote 作成、sync、publish | 外部 repository mirror と distribution 管理。 |
| `package-publishers` | upload / push | 社内 package の publish。 |
| `package-readers` | read | 制限付き repository の download。 |

公開 distribution は Content Guard を付けず、未認証 download を許可する。機密 package は RBAC Content Guard を付け、`package-readers` 以上だけに読ませる。

## Repository 設計

### container / OCI

用途:

- Docker Hub、GHCR、Quay などの mirror / pull-through cache。
- 社内 image の push 先。

名前:

- `container-dockerhub-cache`
- `container-ghcr-cache`
- `container-internal`

Client:

```bash
podman login http://<IP>:33000
podman pull <IP>:33000/container-dockerhub-cache/library/alpine:latest
podman push <IP>:33000/container-internal/app:latest
```

Docker client は HTTP registry を既定で拒否するため、HTTP 運用では各 client に insecure registry 設定が必要になる。可能なら IP SAN 付き HTTPS にする。

### pip / PyPI

用途:

- PyPI mirror / on-demand cache。
- 社内 Python package の upload。

名前:

- `python-pypi-cache`
- `python-internal`

Client:

```bash
pip install <package> --index-url http://<IP>:33000/pypi/python-pypi-cache/simple/ --trusted-host <IP>
twine upload --repository-url http://<IP>:33000/pypi/python-internal/ dist/*
```

HTTP の場合、pip は `trusted-host` が必要になる。

### npm

用途:

- npm registry の sync / pull-through cache。
- 社内 npm package の publish。

名前:

- `npm-registry-cache`
- `npm-internal`

Client:

```bash
npm config set registry http://<IP>:33000/npm/npm-registry-cache/
npm publish --registry http://<IP>:33000/npm/npm-internal/
```

`pulp_npm` は本番投入前に scoped package、dist-tag、package publish、delete/unpublish の動作を検証する。

### Hugging Face

用途:

- Hugging Face Hub content の pull-through cache。
- HF CLI / transformers / huggingface_hub からの利用。

名前:

- `hf-cache`

Client:

```bash
HF_ENDPOINT=http://<IP>:33000/huggingface/hf-cache
huggingface-cli download <repo-id>
```

`pulp_hugging_face` は pull-through cache を中心に評価する。社内独自モデルの publish 管理を Pulp に寄せる場合は、対象ファイル、revision、LFS 相当の扱い、private upstream token の保存方法を別途検証する。

### rpm

用途:

- RHEL compatible / Fedora / Rocky / Alma などの yum/dnf repository mirror。
- 社内 RPM の upload / publish。

名前:

- `rpm-os-cache`
- `rpm-internal`

Client:

```ini
[inferlab-rpm]
name=InferLab RPM
baseurl=http://<IP>:33000/pulp/content/rpm-internal/
enabled=1
gpgcheck=0
```

本番では repository metadata と package signing を有効化する。

### deb

用途:

- Debian / Ubuntu apt repository mirror。
- 社内 deb package の upload / publish。

名前:

- `deb-ubuntu-cache`
- `deb-internal`

Client:

```text
deb [trusted=yes] http://<IP>:33000/pulp/content/deb-internal/ stable main
```

本番では `trusted=yes` を使わず、Release file signing と apt key 配布を行う。

## 実装メモ

- root の `docker-compose.yml` に `./30-developer/docker-compose.yml` を include する。
- `.env` に `PULP_HTTP_HOST_PORT=33000` と `PULP_OIDC_CLIENT_SECRET` を追加する。
- npm と Hugging Face plugin を含むカスタム image は `k5-mot/pulp-custom` で build し、この構成では GHCR から pull する。
- Pulp API と content は同一外部 URL に寄せる。IP 運用では redirect と generated URL の不整合を避ける。
- 管理用 API と upload は Keycloak 認証必須、公開 distribution の content read は未認証にする。
- 初期化は手動 UI ではなく、`pulp-cli` または REST API script で冪等に作る。
- container registry の token auth、anonymous pull、push 権限は最初に重点検証する。
- Pulp UI は全 plugin の完全な管理画面ではない前提で、運用手順は CLI/API を正とする。

## 未決事項

- `pulp_hugging_face` を本番採用できる maturity と対象ユースケース。
- npm の publish / unpublish / dist-tag 運用ルール。
- repository signing policy。
- IP SAN 付き HTTPS を必須にするか、LAN 内 HTTP + client insecure 設定を許容するか。
- reverse proxy 認証方式にするか、Pulp の python-social-auth 連携にするか。

## 参考

- Pulp Project: https://pulpproject.org/
- Pulp OCI Images Quickstart: https://pulpproject.org/pulp-oci-images/docs/admin/tutorials/quickstart/
- Available Pulp Images: https://pulpproject.org/pulp-oci-images/docs/admin/reference/available-images/
- Single-Process Images: https://pulpproject.org/pulp-oci-images/docs/admin/reference/available-images/single-process-images/
- Build your own Pulp image: https://pulpproject.org/pulp-oci-images/docs/admin/guides/build-your-own-pulp-image/
- Pulp Keycloak authentication: https://pulpproject.org/pulpcore/docs/admin/guides/auth/keycloak/
- Pulp external authentication: https://pulpproject.org/pulpcore/docs/admin/guides/auth/external/
- Protect Content: https://pulpproject.org/pulpcore/docs/user/guides/protect-content/
- Pulp Container authentication: https://pulpproject.org/pulp_container/docs/admin/learn/authentication/
- Pulp Python: https://pulpproject.org/pulp_python/
- Pulp NPM: https://pulpproject.org/pulp_npm/
- Pulp Hugging Face: https://pulpproject.org/pulp_hugging_face/docs/admin/
- Pulp RPM: https://pulpproject.org/pulp_rpm/
- Pulp Debian: https://pulpproject.org/pulp_deb/
