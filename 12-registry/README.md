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
curl -fsS "http://${PUBLIC_HOST:-localhost}:${PYPISERVER_HTTP_HOST_PORT:-31200}/simple/" >/dev/null

# VerdaccioのHTTP応答を確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:${VERDACCIO_HTTP_HOST_PORT:-31201}/" >/dev/null

# Docker Registry APIの疎通を確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:${DOCKER_REGISTRY_HTTP_HOST_PORT:-31205}/v2/" >/dev/null
```

期待結果:

- 各endpointがHTTP応答する。
- `rpm-dist`と`deb-dist`がhealthyになる。
- importerのlogにskipまたはimport完了が出る。

失敗条件:

- importerが再起動を繰り返す。
- generated metadataが古いまま更新されない。
- registry公開portへ接続できない。

## References

- [Docker Registry](https://hub.docker.com/_/registry)
