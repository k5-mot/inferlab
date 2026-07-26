# Pulp 3 要件

## 目的

Pulp 3 を使って、開発者向けの社内リポジトリマネージャーを提供する。対象は container / npm / pip / Hugging Face / rpm / deb とする。

## 方針

- `33-registry` は廃止し、開発者向けサービスとして `30-developer` に統合する。
- Pulp 3 は package repository manager として使い、Git forge や CI はこのディレクトリの対象外にする。
- ドメイン名は使わず、`PUBLIC_HOST` に IP アドレスを設定して運用する。
- Web/API/Content は同じ IP と port で公開する。
- 認証は Pulp 内部ユーザーを使う。Pulp 3 では Keycloak / OIDC 認証を使わない。
- 管理 API、同期、アップロード、publish、repository 作成は認証必須にする。
- パッケージ取得は、公開用 distribution では未認証 read を許可する。制限配布が必要な repository だけ RBAC Content Guard を付ける。
- 初期構築は Pulp の REST API または `pulp-cli` で自動化し、Pulp UI は補助的な確認用途に留める。

## Keycloak を使わない理由

Pulp の主な利用経路は CLI、package manager、container runtime である。Keycloak を挟むと、対話 login、token 更新、redirect、証明書、issuer 管理が増え、日常運用の利便性が悪くなる。

このため、Pulp 3 では Pulp 標準の Basic Auth / Session Auth と内部 user / group / role を使う。

## `settings.py` パッチを避ける理由

Pulp は Dynaconf により `PULP_...` 環境変数で settings を上書きできる。DB、Redis、Content URL、import/export 許可 path、container token 設定は環境変数で表現できるため、`/etc/pulp/settings.py` の bind mount は使わない。

`settings.py` パッチを許容するのは、次のいずれかに該当するときだけにする。

- 公式 settings が環境変数では表現できない複雑な Python object を要求する。
- plugin 側の不具合回避として、短期的な monkey patch が必要になる。
- upstream 修正または image 更新までの暫定対応であり、削除条件を文書化できる。

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

想定 port:

| 用途 | Host port | URL |
| --- | --- | --- |
| Pulp Web/API/Content | `33000` | `http://<IP>:33000/` |

IP アドレス運用では、Pulp の base URL に `PUBLIC_HOST` の IP を使う。

```text
PULP_CONTENT_ORIGIN=http://<IP>:33000
PULP_API_ROOT=http://<IP>:33000/pulp/api/v3/
```

## 資材置場

`30-developer/assets/` を管理者の作業用資材置場にする。

Pulp container へ `assets/` を bind mount する構成は採用しない。現在の登録手順は Pulp CLI / REST API upload と container push を使うため、Pulp container から host directory を直接読む必要がない。

`imports/` と `exports/` は Pulp Importer / Exporter を使う場合だけ必要になる。現時点では標準手順に含めない。

## 手動登録

管理対象は [LIST.md](./LIST.md) を正とする。

管理者は `30-developer/assets/` に置いた package file、container image tar、model cache 用の情報を、plugin ごとの upload API、push、または cache 作成操作で Pulp repository へ登録する。

運用手順は Git 管理外の `30-developer/MANUAL.md` に分離する。公開管理する要件文書には、具体的な作業環境や作業経路を記載しない。

## 認可設計

Pulp 内部 group を Pulp role に対応させる。

| Pulp group | Pulp role | 用途 |
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

### pip / PyPI

用途:

- PyPI mirror / on-demand cache。
- 社内 Python package の upload。

名前:

- `python-pypi-cache`
- `python-internal`

### npm

用途:

- npm registry の sync / pull-through cache。
- 社内 npm package の publish。

名前:

- `npm-registry-cache`
- `npm-internal`

`pulp_npm` は本番投入前に scoped package、dist-tag、package publish、delete/unpublish の動作を検証する。

### Hugging Face

用途:

- Hugging Face Hub content の pull-through cache。
- HF CLI / transformers / huggingface_hub からの利用。

名前:

- `hf-cache`

`pulp_hugging_face` は pull-through cache を中心に評価する。社内独自モデルの publish 管理を Pulp に寄せる場合は、対象ファイル、revision、LFS 相当の扱い、private upstream token の保存方法を別途検証する。

### rpm

用途:

- RHEL compatible / Fedora / Rocky / Alma などの yum/dnf repository mirror。
- 社内 RPM の upload / publish。

名前:

- `rpm-os-cache`
- `rpm-internal`

本番では repository metadata と package signing を有効化する。

### deb

用途:

- Debian / Ubuntu apt repository mirror。
- 社内 deb package の upload / publish。

名前:

- `deb-ubuntu-cache`
- `deb-internal`

本番では `trusted=yes` を使わず、Release file signing と apt key 配布を行う。

## 実装メモ

- root の `docker-compose.yml` に `./30-developer/docker-compose.yml` を include する。
- `.env` に `PULP_HTTP_HOST_PORT=33000` を追加する。
- npm と Hugging Face plugin を含むカスタム image は `k5-mot/pulp-custom` で build し、この構成では GHCR から pull する。
- Pulp API と content は同一外部 URL に寄せる。IP 運用では generated URL の不整合を避ける。
- 初期化は手動 UI ではなく、`pulp-cli` または REST API script で冪等に作る。
- container registry の token auth、anonymous pull、push 権限は最初に重点検証する。
- Pulp UI は全 plugin の完全な管理画面ではない前提で、運用手順は CLI/API を正とする。

## 未決事項

- `pulp_hugging_face` を本番採用できる maturity と対象ユースケース。
- npm の publish / unpublish / dist-tag 運用ルール。
- repository signing policy。
- IP SAN 付き HTTPS を必須にするか、HTTP + client insecure 設定を許容するか。
- package file を `30-developer/assets/` へ置いた場合の plugin 別 upload 手順。

## References

- [Pulp Project](https://pulpproject.org/)
- [Pulp settings](https://pulpproject.org/pulpcore/docs/admin/reference/settings/)
- [Pulp import/export repositories](https://pulpproject.org/pulpcore/docs/admin/guides/import-export-repos/)
- [Pulp OCI Images Quickstart](https://pulpproject.org/pulp-oci-images/docs/admin/tutorials/quickstart/)
- [Available Pulp Images](https://pulpproject.org/pulp-oci-images/docs/admin/reference/available-images/)
- [Build your own Pulp image](https://pulpproject.org/pulp-oci-images/docs/admin/guides/build-your-own-pulp-image/)
- [Protect Content](https://pulpproject.org/pulpcore/docs/user/guides/protect-content/)
- [Pulp Container authentication](https://pulpproject.org/pulp_container/docs/admin/learn/authentication/)
- [Pulp Python](https://pulpproject.org/pulp_python/)
- [Pulp NPM](https://pulpproject.org/pulp_npm/)
- [Pulp Hugging Face](https://pulpproject.org/pulp_hugging_face/docs/admin/)
- [Pulp RPM](https://pulpproject.org/pulp_rpm/)
- [Pulp Debian](https://pulpproject.org/pulp_deb/)
