# Registry

開発者向けの package / image / extension registry 構成。

- Python/pip: pypiserver
- Node.js/npm: Verdaccio
- Container image: Harbor
- VS Code Extensions: code-marketplace
- rpm: createrepo_c + nginx
- deb: flat APT repository + nginx

取得済み資材は `30-developer/registry/{pypi,npm,rpm,deb,docker,huggingface,vsix}` に配置する。`30-developer/registry/{pypi,rpm,deb}` に資材を置いて `docker compose --env-file .env --profile developer up -d` を実行すると、各 package registry が自動的に資材を取り込む。npm 資材の Verdaccio への自動投入は既定で無効であり、必要な場合だけ `NPM_IMPORT_ENABLED=true` を指定する。
Windows Clientで資材を取得する場合は、DockerやWSLを使わず `30-developer/scripts/download-assets.ps1` を実行する。registry別に取得したい場合は、同じdirectoryにある `download-pypi-assets.ps1` などを個別に実行する。

Harbor は公式 installer の `harbor.yml` から生成した `docker-compose.yml` を、起動時だけ root compose に重ねて使う。

## References

- [Harbor Installation and Configuration](https://goharbor.io/docs/2.14.0/install-config/)
