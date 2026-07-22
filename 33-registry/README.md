# 33-registry

Sonatype Nexus Repository 3 を使って、pip / npm / Docker の社内レジストリを提供する。

## 方針

- Nexus Repository は `docker.io/sonatype/nexus3:3.94.0` を使う。
- Web UI とパッケージのダウンロードは未認証で許可する。
- パッケージのアップロード、変更、削除、管理画面操作は認証済みユーザーだけに許可する。
- pip / npm は group repository を読み取り用の単一エンドポイントにする。
- Docker は group repository を pull 用、hosted repository を push 用に分ける。
- Keycloak 連携はライセンス条件で構成が分かれるため、無償構成では Nexus のローカルユーザーまたは LDAP を使い、有償の Pro 構成では Keycloak OIDC / SAML を使う。

## ライセンスと社内利用

2026-07-22 時点の公式情報では、Sonatype Nexus Repository Community Edition は無償で開始でき、pip / npm / Docker 形式も CE の機能表で対応している。したがって、小規模で控えめな社内利用であれば無償利用の候補になる。

ただし、CE は EULA の同意が必須で、EULA 同意前はコンポーネントの download / upload がブロックされる。また CE には利用上限があり、40,000 total components または 100,000 requests/day を超えると、上限を下回るまで新規コンポーネント追加ができない。大規模・高可用性・SAML/OIDC SSO・User Token・group repository への publish などが必要な場合は Pro ライセンスが必要になる。

実運用前に、組織の法務・購買観点で Sonatype Nexus Repository Community Edition EULA を確認すること。

## 想定する compose

今後 `33-registry/docker-compose.yml` に次の単一サービスを追加し、root の `docker-compose.yml` の `include` に登録する。

```yaml
services:
  nexus:
    image: docker.io/sonatype/nexus3:3.94.0
    container_name: ${STACK_NAME:-inferlab}-nexus
    restart: unless-stopped
    profiles:
      - registry
    ports:
      - ${NEXUS_HTTP_HOST_PORT:-33000}:8081
      - ${NEXUS_DOCKER_GROUP_HOST_PORT:-33001}:5000
      - ${NEXUS_DOCKER_HOSTED_HOST_PORT:-33002}:5001
    volumes:
      - nexus-data:/nexus-data
    networks:
      - internal-nw

volumes:
  nexus-data:

networks:
  internal-nw:
```

Nexus の公式 Docker image は `/nexus-data` を永続ディレクトリとして使い、プロセスは UID 200 で動く。Docker volume を使う場合は通常そのままでよい。ホストディレクトリを bind mount する場合は UID 200 で書き込み可能にする。

## 初期セットアップ

1. `33-registry/docker-compose.yml` を追加し、root の `docker-compose.yml` に include してから起動する。

```bash
sudo docker compose --env-file .env --profile common --profile registry up -d
```

2. UI を開く。

```text
http://<PUBLIC_HOST>:33000
```

3. 初期 admin password を確認する。

```bash
sudo docker compose exec nexus cat /nexus-data/admin.password
```

4. admin でログインし、Community Edition EULA に同意する。

5. admin password を変更する。

6. `Settings -> Security -> Anonymous Access` で anonymous access を有効化する。

7. `Settings -> Security -> Realms` で次の realm を有効化する。

- `Docker Bearer Token Realm`: Docker client と anonymous pull に必要。
- `npm Bearer Token Realm`: `npm adduser --auth-type=legacy` を使う場合に必要。
- `LDAP Realm`: 無償構成で外部ディレクトリ認証を使う場合に必要。

## 作成する repository

### PyPI

| 名前 | 種別 | 用途 |
| --- | --- | --- |
| `pypi-proxy` | pypi (proxy) | `https://pypi.org/` のキャッシュ |
| `pypi-hosted` | pypi (hosted) | 社内 Python package の publish 先 |
| `pypi-all` | pypi (group) | `pypi-hosted`, `pypi-proxy` をまとめた install 先 |

読み取りは `http://<host>:33000/repository/pypi-all/simple` を使う。publish は `pypi-hosted` にだけ行う。

### npm

| 名前 | 種別 | 用途 |
| --- | --- | --- |
| `npm-proxy` | npm (proxy) | `https://registry.npmjs.org/` のキャッシュ |
| `npm-hosted` | npm (hosted) | 社内 npm package の publish 先 |
| `npm-all` | npm (group) | `npm-hosted`, `npm-proxy` をまとめた install 先 |

読み取りは `http://<host>:33000/repository/npm-all/` を使う。CE では group repository への publish はできないため、publish は `npm-hosted` にだけ行う。

### Docker

| 名前 | 種別 | HTTP connector | 用途 |
| --- | --- | --- | --- |
| `docker-proxy` | docker (proxy) | なし、または任意 | Docker Hub のキャッシュ |
| `docker-hosted` | docker (hosted) | `5001` | 社内 image の push 先 |
| `docker-all` | docker (group) | `5000` | `docker-hosted`, `docker-proxy` をまとめた pull 先 |

Docker は通常の repository path ではなく repository connector port を使う。pull は `<host>:33001`、push は `<host>:33002` を使う。CE では Docker group repository への push はできない。

## 権限設計

anonymous user には read / browse だけを付ける。既定の `nx-anonymous` role は全 format / 全 repository の read / browse を持つため、すべての repository を未認証 download 可能にする用途には合う。repository を限定したい場合は、次のような専用 role を作って anonymous user に割り当てる。

- `nx-healthcheck-read`
- `nx-search-read`
- `nx-repository-view-pypi-pypi-all-browse`
- `nx-repository-view-pypi-pypi-all-read`
- `nx-repository-view-npm-npm-all-browse`
- `nx-repository-view-npm-npm-all-read`
- `nx-repository-view-docker-docker-all-browse`
- `nx-repository-view-docker-docker-all-read`

publish 用には `registry-publisher` role を作り、読み取り用 group repository に read / browse、hosted repository に read / browse / add / edit を与える。delete は必要な運用だけに限定する。

- `nx-repository-view-pypi-pypi-all-browse`
- `nx-repository-view-pypi-pypi-all-read`
- `nx-repository-view-pypi-pypi-hosted-browse`
- `nx-repository-view-pypi-pypi-hosted-read`
- `nx-repository-view-pypi-pypi-hosted-add`
- `nx-repository-view-pypi-pypi-hosted-edit`
- `nx-repository-view-npm-npm-all-browse`
- `nx-repository-view-npm-npm-all-read`
- `nx-repository-view-npm-npm-hosted-browse`
- `nx-repository-view-npm-npm-hosted-read`
- `nx-repository-view-npm-npm-hosted-add`
- `nx-repository-view-npm-npm-hosted-edit`
- `nx-repository-view-docker-docker-all-browse`
- `nx-repository-view-docker-docker-all-read`
- `nx-repository-view-docker-docker-hosted-browse`
- `nx-repository-view-docker-docker-hosted-read`
- `nx-repository-view-docker-docker-hosted-add`
- `nx-repository-view-docker-docker-hosted-edit`

管理者には `nx-admin` 相当の管理 role を別に割り当て、publish 権限と管理権限を分ける。

## Keycloak 認証

### 無償構成

Nexus Repository CE で Keycloak を OIDC / SAML の SSO IdP として直接使う構成は採用しない。公式ドキュメント上、OIDC は Nexus Repository Pro または Cloud、SAML は Nexus Repository Pro の機能である。

無償で中央認証に寄せる場合は、Nexus の LDAP 連携を使う。Keycloak と Nexus が同じ LDAP ディレクトリを参照する構成にすれば、利用者管理は LDAP 側に集約できる。ただし、Keycloak 自体を OIDC IdP とする SSO ではない。

実装候補:

- 認証: Nexus Local Authenticating Realm + LDAP Realm
- 認可: LDAP group を Nexus role に mapping
- publish group: `registry-publishers`
- admin group: `registry-admins`

### Pro 構成

Keycloak を直接使う場合は Pro ライセンスで OIDC または SAML を設定する。

- OIDC: Nexus Repository 3.86 以降の Pro / Cloud で対応。Keycloak は OpenID Provider として使える。
- SAML: Pro 機能。Keycloak は Sonatype の SAML tested providers に含まれる。
- Nexus 側で Keycloak group claim を Nexus role に mapping し、`registry-publisher` を割り当てる。

注意点として、pip / npm / Docker の CLI はブラウザ SSO リダイレクトを扱わない。CLI publish には、Nexus が受け付ける Basic 認証、npm bearer token、または Pro の User Token など、CLI 互換の credential が必要になる。

## クライアント設定

### pip install

未認証 download の場合:

```bash
pip install requests --index-url http://<host>:33000/repository/pypi-all/simple --trusted-host <host>
```

恒久設定:

```ini
[global]
index-url = http://<host>:33000/repository/pypi-all/simple
trusted-host = <host>
```

### PyPI publish

`~/.pypirc` に publish 用 credential を設定する。

```ini
[distutils]
index-servers =
    nexus

[nexus]
repository = http://<host>:33000/repository/pypi-hosted/
username = <username>
password = <password-or-token>
```

publish する。

```bash
python -m build
twine upload -r nexus dist/*
```

### npm install

未認証 download の場合:

```bash
npm config set registry http://<host>:33000/repository/npm-all/
npm install
```

### npm publish

`npm Bearer Token Realm` を有効化してから、publish 用ユーザーで login する。

```bash
npm adduser --auth-type=legacy --registry=http://<host>:33000/repository/npm-hosted/
npm publish --registry=http://<host>:33000/repository/npm-hosted/
```

### Docker pull

未認証 pull の場合:

```bash
docker pull <host>:33001/alpine:latest
docker pull <host>:33001/<image>:<tag>
```

Docker Hub の official image は、Nexus の内部表示では `library/<name>` として扱われる。

### Docker push

publish 用ユーザーで hosted connector port に login する。repository path は付けない。

```bash
docker login <host>:33002
docker tag <image>:<tag> <host>:33002/<image>:<tag>
docker push <host>:33002/<image>:<tag>
```

push 前に Docker repository の `Allow anonymous Docker pulls for this repository` は pull 用 repository にだけ有効化し、publish 用 role には `docker-hosted` の add / edit を付ける。

## 運用メモ

- HTTPS 終端は reverse proxy 側で行う。pip は HTTP の場合 `trusted-host` が必要になるため、社内 CA 付き HTTPS 化を推奨する。
- Docker client は HTTPS を前提にするため、HTTP のまま使う場合は各 client 側で insecure registry 設定が必要になる。
- Docker の incomplete upload や unused manifest を掃除する scheduled task を設定する。
- CE の利用上限に近づいたら、cleanup policy と Docker cleanup task を設定し、必要なら Pro 移行を検討する。
- EULA 同意、anonymous access、realm、repository、role は UI で初回設定し、安定後に REST API または script 化する。

## 参考

- Sonatype Nexus Repository: https://help.sonatype.com/en/sonatype-nexus-repository.html
- Sonatype Docker image: https://github.com/sonatype/docker-nexus3
- 公式 docker-compose.yml: https://github.com/sonatype/docker-nexus3/blob/main/docker-compose.yml
- Anonymous Access: https://help.sonatype.com/en/anonymous-access.html
- Docker Authentication: https://help.sonatype.com/en/docker-authentication.html
- npm Security: https://help.sonatype.com/en/npm-security.html
- PyPI CLI Usage: https://help.sonatype.com/en/pypi-cli-usage.html
- Feature Matrix: https://help.sonatype.com/en/nexus-repository-feature-matrix.html
- Usage Center: https://help.sonatype.com/en/usage-center.html
- OpenID Connect: https://help.sonatype.com/en/openid-connect.html
- SAML: https://help.sonatype.com/en/saml.html
