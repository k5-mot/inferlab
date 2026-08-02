# Playwright E2E smoke tests

必要な Docker Compose profile だけを起動し、ブラウザ経由で認証と主要操作を検証します。通常の commit 時には重いため、pre-commit の `manual` stage として実行します。

## BookStack

BookStack smoke test は `keycloak` と `bookstack` profile だけを起動し、Keycloak でログインした後に新規 Book を作成します。

```bash
# KeycloakとBookStackだけを起動し、OIDC認証後に新規Bookを作成する。
tests/e2e/run-playwright-smoke.sh bookstack
```

期待結果:

- Keycloak、Keycloak HTTPS、BookStack、関連DBだけが一時 Compose project として起動する。
- BookStack の OIDC login から Keycloak user `admin` で認証できる。
- BookStack に `Codex Smoke Book ...` という検証用 Book が作成される。
- 検証後、一時 Compose project、container、volume、network が削除される。

失敗条件:

- Docker daemon、Docker Compose plugin、Node.js、npm、Python 3 のいずれかを利用できない。
- Keycloak または BookStack が `healthy` にならない。
- OIDC 認証に失敗する。
- BookStack の新規 Book 作成画面または作成結果を確認できない。

失敗時の調査用 artifact は `tests/e2e/artifacts/` に保存されます。この directory は Git 管理対象外です。
