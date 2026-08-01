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

## References

- [Docker Registry](https://hub.docker.com/_/registry)
