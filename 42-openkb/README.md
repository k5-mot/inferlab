# LLM Wiki Platform

OpenKBをKnowledge Compilerとして利用し、社内sourceの取り込み、定期compile、Wiki.js LLM Wikiへの公開を管理するserviceである。

現時点の `config.yaml` は安全な初期状態としてすべてのConnectorとpipelineを無効化している。利用するsourceを `enabled: true` に変更し、参照されるcredential環境変数を設定した後にcontainerを再起動する。

## 開発環境

```bash
# project依存関係と開発toolを同期する。
uv sync --project 42-openkb

# unit testを実行する。
uv run --project 42-openkb pytest 42-openkb/tests

# lintを実行する。
uv run --project 42-openkb ruff check 42-openkb/src 42-openkb/tests

# formatを変更せず検査する。
uv run --project 42-openkb ruff format --check 42-openkb/src 42-openkb/tests

# static type checkを実行する。
uv run --project 42-openkb mypy --config-file 42-openkb/pyproject.toml 42-openkb/src
```

期待結果:

- `uv sync`が `42-openkb/.venv` を作成する。
- test、lint、format、type checkがすべて終了code 0で完了する。

失敗基準:

- `config.yaml` のschema違反またはcredential参照不足がある場合、serviceは起動してはならない。
- test、lint、format、type checkのいずれかが終了code 0以外なら変更を完了扱いにしてはならない。

## 設定反映

MVPでは設定を起動時にだけ読み込む。`config.yaml` またはcredential環境変数を変更した場合は、`llm-wiki-api` containerを再起動する。稼働中のreload endpointは提供しない。

API processがschedulerとjob実行を所有する。MVPではworker containerを分離しないため、同じscheduleを複数processが登録することはない。

## 起動

```bash
# Wiki.jsとOpenKB pipelineをbuildして起動する。
docker compose --profile wikijs --profile openkb up -d --build wikijs openkb llm-wiki-api

# containerとhealth状態を確認する。
docker compose ps wikijs openkb llm-wiki-api
```

期待結果:

- `wikijs`、`openkb`、`llm-wiki-api`がhealthyになる。
- 管理APIのSwagger UIを `http://localhost:34200/docs` で表示できる。
- `config.yaml` の初期状態ではschedule jobは登録されず、外部sourceへrequestを送らない。

失敗基準:

- `llm-wiki-api`が起動直後に終了した場合、container logに示されたconfig schemaまたはcredential環境変数を修正する。
- OpenKBがhealthyにならない場合、OpenKB image buildとvolume権限を確認する。

Rollback:

```bash
# pipeline containerを停止し、Source StoreとOpenKB volumeは保持する。
docker compose stop llm-wiki-api openkb
```

## References

- [OpenKB REST API](https://github.com/VectifyAI/OpenKB/blob/main/examples/rest-api/README.md)
- [Wiki.js GraphQL API](https://docs.requarks.io/dev/api)
- [GitLab REST API](https://docs.gitlab.com/api/api_resources/)
- [Zulip REST API](https://zulip.com/api/rest)
- [Nextcloud WebDAV API](https://docs.nextcloud.com/server/stable/developer_manual/client_apis/WebDAV/basic.html)
- [Kaneo API Reference](https://kaneo.app/docs/api-reference/introduction)
