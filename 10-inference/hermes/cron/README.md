# Hermes cron

このdirectoryは、Hermes-Agent container内の`/opt/data/cron`へbind mountする。

Git管理する対象:

- `jobs.json`: Hermes gateway schedulerが読むscheduled job定義。
- `prompts/`: cron jobから参照する長い運用prompt。

Git管理しない対象:

- `executions.db`: Hermesが記録する実行履歴。
- `.tick.lock`、`.jobs.lock`、`ticker_*`: schedulerのlockとheartbeat。
- `output/`: `deliver: local`の実行結果。
- `state/`: jobが保持するcheckpoint。

`jobs.json`を直接編集した場合は、Hermes dashboardまたは次のcommandで読み込み状態を確認する。

```bash
# Hermes container内でcron job一覧を確認する。
docker compose --profile hermes-agent exec hermes-agent hermes cron list
```

期待結果:

- `couchdb-to-llmwiki`がactiveとして表示される。
- `Next run`が現在時刻より後の時刻に設定される。

失敗条件:

- `jobs.json`のJSON構文が壊れている。
- Hermes gatewayが`/opt/data/cron/jobs.json`を読み込めない。
