# Registry

開発者向けの package / image / extension registry 構成。

- Python/pip: pypiserver
- Node.js/npm: Verdaccio
- Container image: Harbor
- VS Code Extensions: code-marketplace
- rpm: createrepo_c + nginx
- deb: flat APT repository + nginx

`30-developer/pypi`、`30-developer/npm`、`30-developer/rpm`、`30-developer/deb` に取得済み資材を置いて `docker compose --env-file .env --profile developer up -d` を実行すると、各 registry が自動的に資材を取り込む。
Windows Clientで資材を取得する場合は、DockerやWSLを使わず `30-developer/scripts/download-assets.ps1` を実行する。

Harbor は公式 installer の `harbor.yml` から生成した `docker-compose.yml` を、起動時だけ root compose に重ねて使う。

## References

- [Harbor Installation and Configuration](https://goharbor.io/docs/2.14.0/install-config/)
