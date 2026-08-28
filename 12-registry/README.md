# Registry

開発者向けの package / image / extension registry 構成。

- Python/pip: pypiserver
- Node.js/npm: Verdaccio
- Container image: Docker Registry
- rpm: createrepo_c + nginx
- deb: reprepro + nginx

取得済み資材は `/srv/12-registry/{rpm,deb,pypi,npm-packages,vsix}` に配置する。`docker compose --env-file .env --profile registry up -d` を実行すると、rpm、deb、PyPI package、npm package、VSIX file は各 registry へ自動的に反映される。
Windows Clientで資材を取得する場合は、DockerやWSLを使わず `12-registry/scripts/download-assets.ps1` を実行する。registry別に取得したい場合は、同じdirectoryにある `download-pypi-assets.ps1` などを個別に実行する。

| Directory | 対象 | 反映先 |
| --- | --- | --- |
| `/srv/12-registry/rpm` | `.rpm` | createrepo_c が metadata を生成し、nginx が配信する。 |
| `/srv/12-registry/deb` | `.deb` | reprepro が `/srv/12-registry/deb/public` へ APT repository を生成し、nginx が配信する。 |
| `/srv/12-registry/pypi` | `.whl`、`.tar.gz`、`.zip` | pypiserver が配信する。 |
| `/srv/12-registry/npm-packages` | `.tgz` | Verdaccio へ publish する。 |
| `/srv/12-registry/vsix` | `.vsix` | Code Marketplace importer が配信storageへ反映する。 |
| `/srv/oci-archive` | `docker save` 形式の `.tar` | Container engineへ手動loadするための入力資材。 |

Container image registry は Docker 公式 `registry` image を使用する。

PyPIserverはpackage資材を変更しない配信専用serviceとして、UID/GID `9898`の非root userで`pypi-server`を直接起動する。image標準のentrypointはpackage directoryの所有権変更を試行するため使用せず、`/srv/12-registry/pypi`のread-only mountを維持する。

## Airgap構成

各registryは、未登録の資材を外部registryから取得しない。

- PyPIserverは`--disable-fallback`を指定し、未登録packageを`https://pypi.org/simple/`へredirectせずHTTP 404を返す。
- Verdaccioはoffline publishを許可し、`uplinks`を空にしてすべてのpackage規則から`proxy`を除外する。Web UIのGravatarも無効化する。
- Docker Registryはpull-through cache用の`proxy`を設定しない。
- Code Marketplace、RPM repository、APT repositoryはlocal storageだけを配信する。

配信serviceと同期serviceのcontainer image、および配信する全資材は、Registry serverをairgap環境へ移す前に取得しておく。

## 起動時初期化

このstackは、起動後に取得済み資材を各registryへ自動反映する常駐importerを持つ。

| Service | 初期化・同期内容 |
| --- | --- |
| `code-marketplace-importer` | `/srv/12-registry/vsix`の`.vsix`をfingerprint化し、変更がある場合だけCode Marketplace storageへ追加する。 |
| `npm-importer` | `/srv/12-registry/npm-packages`の`.tgz`をVerdaccioへ冪等にpublishする。 |
| `createrepo_c` | `/srv/12-registry/rpm`を定期的にRPM repository metadataへ反映する。 |
| `reprepro` | `/srv/12-registry/deb`を定期的にAPT repository metadataへ反映し、`/srv/12-registry/deb/public`へ公開用treeを生成する。 |

`docker-registry`へのimage archive登録は自動では行わない。`/srv/oci-archive`は手動loadまたはpush用の入力資材置き場として扱う。

## 起動

```bash
# registry stackを起動し、package資材の同期処理を開始する。
sudo docker compose --env-file .env --profile registry up -d
```

期待結果:

- PyPIserver、Verdaccio、Code Marketplace、Docker Registryが応答する。
- `/srv/12-registry/rpm`のRPMが`rpm-dist`から配信される。
- `/srv/12-registry/deb/public`にAPT repository metadataが生成される。
- `/srv/12-registry/npm-packages`のnpm packageがVerdaccioへpublishされる。

失敗条件:

- `npm-importer`が認証token不一致でpublishに失敗する。
- `createrepo_c`または`reprepro`が入力packageの不整合で失敗する。
- bind mount元の`/srv/12-registry/*` directoryをcontainerから読めない。

## 確認手順

```bash
# registry profileのcontainer状態を確認する。
sudo docker compose --env-file .env --profile registry ps

# PyPIserverのsimple indexを確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:31200/simple/" >/dev/null

# 未登録PyPI packageが外部indexへredirectされずHTTP 404になることを確認する。
test "$(curl -sS -o /dev/null -w '%{http_code}' "http://${PUBLIC_HOST:-localhost}:31200/simple/airgap-missing-package-does-not-exist/")" = "404"

# VerdaccioのHTTP応答を確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:31201/" >/dev/null

# Docker Registry APIの疎通を確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:31205/v2/" >/dev/null
```

期待結果:

- 各endpointがHTTP応答する。
- PyPIserverが未登録packageへHTTP 404を返す。
- `rpm-dist`と`deb-dist`がhealthyになる。
- importerのlogにskipまたはimport完了が出る。

失敗条件:

- importerが再起動を繰り返す。
- generated metadataが古いまま更新されない。
- registry公開portへ接続できない。

## References

- [pypiserver](https://github.com/pypiserver/pypiserver)
- [Verdaccio: Linking a Remote Registry](https://verdaccio.org/docs/linking-remote-registry/)
- [Verdaccio: Configuration File](https://verdaccio.org/docs/configuration/)
- [Verdaccio: Web Configuration](https://verdaccio.org/docs/webui/)
- [CNCF Distribution: Registry Configuration](https://distribution.github.io/distribution/about/configuration/)
- [code-marketplace](https://github.com/coder/code-marketplace)
