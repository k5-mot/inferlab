# LLM Wiki Platform

OpenKBをKnowledge Compilerとして利用し、社内sourceの取り込み、定期compile、BookStack LLM Wikiへの公開を管理するserviceである。

現時点の `config.yaml` は安全な初期状態としてすべてのConnectorとpipelineを無効化している。利用するsourceを `enabled: true` に変更し、参照されるcredential環境変数を設定した後にcontainerを再起動する。

## 開発環境

```bash
# project依存関係と開発toolを同期する。
uv sync --project 41-openkb

# unit testを実行する。
uv run --project 41-openkb pytest 41-openkb/tests

# lintとformat検査を実行する。
uv run --project 41-openkb ruff check 41-openkb/src 41-openkb/tests
uv run --project 41-openkb ruff format --check 41-openkb/src 41-openkb/tests

# static type checkを実行する。
uv run --project 41-openkb mypy --config-file 41-openkb/pyproject.toml 41-openkb/src
```

期待結果:

- `uv sync`が `41-openkb/.venv` を作成する。
- test、lint、format、type checkがすべて終了code 0で完了する。

失敗基準:

- `config.yaml` のschema違反またはcredential参照不足がある場合、serviceは起動してはならない。
- test、lint、format、type checkのいずれかが終了code 0以外なら変更を完了扱いにしてはならない。

## BookStack integration test

起動済みの実BookStackでPublisher lifecycleを検証する場合、次の環境変数を MUST 設定する。

- `BOOKSTACK_INTEGRATION_BASE_URL`
- `BOOKSTACK_INTEGRATION_TOKEN_ID`
- `BOOKSTACK_INTEGRATION_TOKEN_SECRET`
- `BOOKSTACK_INTEGRATION_SUFFIX`

`BOOKSTACK_INTEGRATION_SUFFIX` はrunごとに一意な値を MUST 使用する。tokenにはAPI accessとshelf、book、pageのview、create、update権限が必要であり、管理者権限やdelete権限は不要である。testはsuffix付きのshelf、book、pageを作成し、結果をBookStack上へ保持する。

```bash
# 起動済みBookStackに対してPublisher lifecycle integration testを実行する。
uv run --project 41-openkb pytest -m integration 41-openkb/tests/integration
```

期待結果:

- 初回publishでshelf 1件、book 2件、page 2件が作成される。
- 再publishは変更なし、本文変更はupdate、生成元削除はunavailable表示として処理される。
- OpenKB wikilinkがBookStackの `/link/{page_id}` へ変換される。

失敗基準:

- 4xxまたは5xx response、重複作成、本文不一致、shelfへのbook関連付け漏れが発生した場合は失敗とする。

## 設定反映

MVPでは設定を起動時にだけ読み込む。`config.yaml` またはcredential環境変数を変更した場合は、`llm-wiki-api` containerを再起動する。稼働中のreload endpointは提供しない。

API processがschedulerとjob実行を所有する。MVPではworker containerを分離しないため、同じscheduleを複数processが登録することはない。

## 起動

```bash
# BookStackとOpenKB pipelineをbuildして起動する。
docker compose --profile bookstack --profile openkb up -d --build bookstack openkb llm-wiki-api

# containerとhealth状態を確認する。
docker compose ps bookstack openkb llm-wiki-api
```

期待結果:

- `bookstack`、`openkb`、`llm-wiki-api`がhealthyになる。
- 管理APIのSwagger UIを `http://localhost:34100/docs` で表示できる。
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
- [BookStack API](https://www.bookstackapp.com/docs/admin/hacking-bookstack/)
- [GitLab REST API](https://docs.gitlab.com/api/api_resources/)
- [Zulip REST API](https://zulip.com/api/rest)
- [Nextcloud WebDAV API](https://docs.nextcloud.com/server/stable/developer_manual/client_apis/WebDAV/basic.html)
- [Kaneo API Reference](https://kaneo.app/docs/api-reference/introduction)
