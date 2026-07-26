# Registry

開発者向けの package / image / extension registry 構成。

- Python/pip: pypiserver
- Node.js/npm: Verdaccio
- Container image: Harbor
- VS Code Extensions: code-marketplace
- rpm: createrepo_c + nginx
- deb: aptly + nginx

Harbor は公式 installer の `harbor.yml` から生成した `docker-compose.yml` を、起動時だけ root compose に重ねて使う。

## References

- [Harbor Installation and Configuration](https://goharbor.io/docs/2.14.0/install-config/)
