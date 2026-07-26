# 30-developer

Pulp 3 を使う開発者向け package / container registry。

## 参照先

- 管理対象一覧: [LIST.md](./LIST.md)

## 接続情報

| 用途 | URL |
| --- | --- |
| Pulp API | `http://<IP>:33000/pulp/api/v3/` |
| Pulp Content | `http://<IP>:33000/pulp/content/` |
| Container Registry | `http://<IP>:33000/` |

認証は Pulp 内部ユーザーを使う。Keycloak / OIDC は使わない。
