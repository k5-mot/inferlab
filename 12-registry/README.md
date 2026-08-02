# Registry

開発者向けの package / image / extension registry 構成。

- Python/pip: pypiserver
- Node.js/npm: Verdaccio
- Container image: Docker Registry
- rpm: createrepo_c + nginx
- deb: reprepro + nginx

取得済み資材は `12-registry/registry/{rpm,deb,wheel,npm-packages,docker-archive}` に配置する。`docker compose --env-file .env --profile registry up -d` を実行すると、rpm、deb、wheel、npm package は各 registry へ自動的に反映される。
Windows Clientで資材を取得する場合は、DockerやWSLを使わず `12-registry/scripts/download-assets.ps1` を実行する。registry別に取得したい場合は、同じdirectoryにある `download-pypi-assets.ps1` などを個別に実行する。

| Directory | 対象 | 反映先 |
| --- | --- | --- |
| `registry/rpm` | `.rpm` | createrepo_c が metadata を生成し、nginx が配信する。 |
| `registry/deb` | `.deb` | reprepro が `registry/deb/public` へ APT repository を生成し、nginx が配信する。 |
| `registry/wheel` | `.whl`、`.tar.gz`、`.zip` | pypiserver が配信する。 |
| `registry/npm-packages` | `.tgz` | Verdaccio へ publish する。 |
| `registry/docker-archive` | `docker save` 形式の `.tar` | Docker Registry へ手動 push するための入力資材。 |

Container image registry は Docker 公式 `registry` image を使用する。

## 起動時初期化

このstackは、起動後に取得済み資材を各registryへ自動反映する常駐importerを持つ。

| Service | 初期化・同期内容 |
| --- | --- |
| `code-marketplace-importer` | `registry/vsix`の`.vsix`をfingerprint化し、変更がある場合だけCode Marketplace storageへ追加する。 |
| `npm-importer` | `registry/npm-packages`の`.tgz`をVerdaccioへ冪等にpublishする。 |
| `createrepo_c` | `registry/rpm`を定期的にRPM repository metadataへ反映する。 |
| `reprepro` | `registry/deb`を定期的にAPT repository metadataへ反映し、`registry/deb/public`へ公開用treeを生成する。 |

`docker-registry`へのimage archive登録は自動では行わない。`registry/docker-archive`は手動push用の入力資材置き場として扱う。

## 起動

```bash
# registry stackを起動し、package資材の同期処理を開始する。
sudo docker compose --env-file .env --profile registry up -d
```

期待結果:

- PyPIserver、Verdaccio、Code Marketplace、Docker Registryが応答する。
- `registry/rpm`のRPMが`rpm-dist`から配信される。
- `registry/deb/public`にAPT repository metadataが生成される。
- `registry/npm-packages`のnpm packageがVerdaccioへpublishされる。

失敗条件:

- `npm-importer`が認証token不一致でpublishに失敗する。
- `createrepo_c`または`reprepro`が入力packageの不整合で失敗する。
- bind mount元の`registry/*` directoryをcontainerから読めない。

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
