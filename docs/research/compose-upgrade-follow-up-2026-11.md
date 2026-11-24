# Compose アップグレード追跡調査

## 調査範囲

2026 年 11 月 24 日時点の公式ドキュメントと公式リポジトリ、および更新後 Compose の実測結果を基に、Ollama、OpenClaw、PostgreSQL 18、NGINX、Zulip、Dify、GitLab のアップグレード後に必要な判断を整理する。

## Ollama

### 結論

Ollama の現行料金体系では、Cloud の全モデルが usage credit による従量課金である。無料サブスクリプションを意味する `Pay as you go` は月額が 0 ドルであるだけで、Cloud 推論そのものは無償ではない。費用ゼロを要件にする場合は、Cloud tag ではなくローカルモデルを使う必要がある。

公式ライブラリは `nemotron-3-nano:30b-cloud` を掲載しているが、実環境では manifest が取得できなかった。Cloud model は廃止され得ることが公式 lifecycle に明記されているため、ライブラリ掲載だけでなく、運用中の Ollama server から pull できることを採用条件にする。

### 推奨

- 費用ゼロを優先する場合は `nemotron-3-nano:4b` を第一候補とする。公式ライブラリに存在し、約 2.8 GB から 2.9 GB で、日本語と tool calling をサポートする。
- 既存の 30B 相当の品質を優先し、ホストに約 18 GB から 24 GB の model data と十分な推論メモリがある場合は、ローカルの `nemotron-3-nano:30b` を候補とする。
- `gemma4:31b-cloud` と `gpt-oss:20b-cloud` も従量課金対象であるため、「無料モデル」として扱わない。
- 起動時 pull に失敗した model が init service 全体を失敗させないよう、model ごとの成否を記録し、必須 model と任意 model を区別する。

実環境では約29 GiBのRAMに対して約7 GiBだけがavailableで、2 GiBのswapも使用済みだったため、30Bのローカルmodelは採用しなかった。取得不能だった`nemotron-3-nano:30b-cloud`を`nemotron-3-nano:4b`へ置換し、約2.8 GBのpullとLiteLLM経由の実推論が成功した。

## OpenClaw

### volume 削除の評価

`openclaw-data` の削除は推奨しない。現在 bind mount されている managed config と `AGENTS.md`、`IDENTITY.md`、`SOUL.md` だけでは OpenClaw の状態を復元できない。

`$OPENCLAW_STATE_DIR` には次の永続データが保存される。

- shared auth profile を含む `state/openclaw.sqlite`
- agent ごとの auth profile、session、transcript を含む `agents/<agentId>/agent/openclaw-agent.sqlite`
- channel/provider credential
- legacy credential とその migration source
- session archive、plugin、shared skill、state ownership 情報

このため volume を削除すると、persona の一部は Git から戻せても、認証、会話履歴、channel state、plugin state は失われる。新規環境として作り直し、再認証と履歴消失を許容する場合だけ削除できる。

### 推奨手順

1. Gateway を停止する。
2. OpenClaw の検証付き full archive と、停止中 volume の raw archive を別ストレージへ保存する。
3. 同じ state volume と書き込み可能な config copy を候補 image に mount し、`doctor --fix --non-interactive` を一度だけ実行する。
4. 修正後 config と repository 管理 config の差分を確認し、必要な schema 変更だけ repository に反映する。
5. read-only managed config を戻して Doctor lint、post-upgrade、SQLite validation を通す。
6. Gateway を一つだけ起動する。

現在の `EBUSY` と migration custody の拒否は、state を消す理由ではなく、writer を停止して Doctor に migration ownership を与えるべき状態を示す。公式 Docker 文書も、lock file や state を削除せず、同じ mount で Doctor を実行するよう要求している。

実volumeをread-onlyで確認すると、`agents/main/agent/openclaw-agent.sqlite`、WAL、migration前backup、Discord session archive、model設定が保存されていた。これらは現在のbind mountに含まれないため、volume削除で実データを失うことも確認できた。

## Kaneo の PostgreSQL 16 から 18 への移行

### 原因

PostgreSQL official image は 18 から `PGDATA` を `/var/lib/postgresql/18/docker` に変更し、image の `VOLUME` も `/var/lib/postgresql` に変更した。既存 Compose は volume を従来の `/var/lib/postgresql/data` に mount しているため、18 の entrypoint が古い cluster を unused mount と判定して起動を拒否する。

PostgreSQL major version を跨ぐ data directory は直接再利用できない。今回の履歴では Kaneo は PostgreSQL 16 から 18 へ更新されているため、論理 dump/restore または `pg_upgrade` が必要である。

### 推奨手順

データ量が小さい Kaneo では、rollback が明確な論理 dump/restore を第一候補とする。

1. Kaneo と PostgreSQL 16 を停止し、既存 volume の raw archive を取得する。
2. PostgreSQL 16 image で旧 volume を起動し、新しい PostgreSQL client を使って role と Kaneo database の論理 dump を取得する。
3. 新しい volume を `/var/lib/postgresql` に mount し、PostgreSQL 18 の空 cluster を作成する。
4. role、database、schema/data の順に restore する。
5. table 数、主要 table の row 数、Kaneo login と read/write 操作を確認する。
6. 検証期間中は旧 volume と dump を保持する。

データ量が大きく停止時間を短縮する場合だけ `pg_upgrade` を選ぶ。その場合は PostgreSQL 18 の `pg_upgrade` binary を使い、旧 16 と新 18 の binary/data directory を同時に参照させ、最初に `--check` を実行する。`--link` は高速だが、新 cluster 起動後に旧 cluster を安全な rollback 元として使えなくなるため、Kaneo では通常 copy mode の方が安全である。

## registry の NGINX healthcheck

### 実測した原因

`rpm-dist`と`deb-dist`の失敗原因はrepositoryが空であることではなく、container portの不一致である。`nginx:1.31.10-alpine`の既定設定はport 80で待ち受けるが、Composeはhost portをcontainerの8080へ転送し、healthcheckも`127.0.0.1:8080`をprobeしている。実行時には`Connection refused`となった。

port mappingを`31203:80`と`31204:80`へ変更し、healthcheckを`127.0.0.1:80`へ合わせる必要がある。その後に403が発生する場合は、NGINXの`autoindex`が既定で`off`であるため、専用readiness endpointを用意するか、実際のrepository metadataをprobeする。RPMは`repodata/repomd.xml`、DEBは`dists/stable/Release`をcontent readinessに使用すると、配信processとpublish完了を区別できる。

## Zulip

`zulip-redis`だけを起動した実測では、healthcheck以前にValkey本体がrestart loopへ入った。logは`Can't handle RDB format version 14`とfatalなdatabase load failureを示した。原因はpassword不一致ではなく、既存`zulip-redis-data` volume内のRDBが、更新後の`valkey:9.2.0-alpine3.24`で読み込めないことである。

volumeを消すとqueue/cache系の状態を失うため、先に旧imageで起動して互換形式へexportするか、データを破棄可能と判断したうえでvolumeを再作成する必要がある。復旧後は、credentialをcommand lineへ露出しないようhealthcheckの`-a`を`VALKEYCLI_AUTH`へ変更することも推奨するが、これは今回のrestart原因ではない。

## Dify

Dify 1.20.0 は API、worker、web、Agent Backend、Local Sandbox を同じ release cohort へ揃える必要がある。公式構成では Agent Backend が Redis、plugin daemon、local sandbox に依存し、Local Sandbox の endpoint と token は `DIFY_AGENT_LOCAL_SANDBOX_ENDPOINT` と `DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN` で設定する。

全serviceを起動した実測では、依存serviceはhealthyになった一方、`dify-agent-backend`だけがrestart loopへ入った。Pydanticの設定検証は`DIFY_AGENT_SANDBOX_FILES_BASE_URL is required for Agent Stub file transfers and Config downloads.`として終了した。現構成には必須の`DIFY_AGENT_SANDBOX_FILES_BASE_URL`がなく、sandbox接続にも旧名の`DIFY_AGENT_SHELLCTL_ENTRYPOINT`と`DIFY_AGENT_SHELLCTL_AUTH_TOKEN`を使用している。

公式1.20.0構成へ合わせ、少なくとも次を設定する必要がある。

- `DIFY_AGENT_RUNTIME_BACKEND=local`
- `DIFY_AGENT_LOCAL_SANDBOX_ENDPOINT=http://dify-local-sandbox:5004`
- `DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN=<local sandboxと同じtoken>`
- `DIFY_AGENT_STUB_API_BASE_URL=http://dify-agent-backend:5050/agent-stub`
- `DIFY_AGENT_SANDBOX_FILES_BASE_URL=http://dify-api:5001`

Dify 公式は Docker Compose 2.35.0 以上を要求している。古い Compose では `.env` override precedence が異なり、service 間で token が不一致になる可能性がある。

## GitLab

GitLab 19 の single-node baseline は 8 vCPU、16 GB memory で、memory-constrained 構成でも 8 GB 以上が目安である。Omnibus container は初回起動や upgrade 中に database migration と service 再構成を行うため、通常起動より一時的な負荷が高い。

他 stack を停止せずに GitLab service だけを起動する試験は、runner 由来の負荷を除外できるが、host 全体のリソース不足は除外できない。判断には次を分けて記録する。

- GitLab container の health status と起動に要した時間
- container の OOM kill、memory peak、CPU throttling
- host の available memory と swap activity
- `gitlab-ctl status` で停止している内部 service
- database migration error の有無

GitLab service 単体でも同じ同期遅延または unhealthy が発生し、OOM や swap 増大がない場合は upgrade/migration または healthcheck 側を調査する。単体では正常で、他 profile 併用時だけ再発する場合は resource contention を主因と判断できる。

### 実測結果

runnerを起動せず`gitlab`だけを起動したところ、約3分30秒でhealthyになり、`/-/readiness`は`status: ok`を返した。再起動、OOM kill、migration errorはなく、`gitlab-ctl status`でも全内部serviceがrunになった。一方、安定化直後のGitLabは約4.7 GiB、約2 CPU、605 processを使用し、同時稼働中profileを含むhostのavailable memoryは約3.7 GiB、2 GiBのswapは使用済みだった。

この結果ではGitLab単体のアップグレード障害は再現せず、他profile併用時のresource contentionが第一候補になる。今後は同じ症状が再発した時点のOOM、swap、CPU throttlingを取得し、GitLabだけの問題として扱うかを判断する。

## References

- [Ollama Pricing](https://ollama.com/pricing)
- [Ollama Cloud](https://docs.ollama.com/cloud)
- [Ollama nemotron-3-nano](https://ollama.com/library/nemotron-3-nano)
- [OpenClaw: Where things live on disk](https://github.com/openclaw/openclaw/blob/main/docs/help/faq/where-things-live-on-disk.md)
- [OpenClaw Docker](https://docs.openclaw.ai/docker)
- [OpenClaw Backups](https://docs.openclaw.ai/install/backups)
- [PostgreSQL official image: PGDATA](https://hub.docker.com/_/postgres#pgdata)
- [PostgreSQL 18: pg_upgrade](https://www.postgresql.org/docs/18/pgupgrade.html)
- [PostgreSQL: Upgrading a cluster](https://www.postgresql.org/docs/current/upgrading.html)
- [NGINX autoindex module](https://nginx.org/en/docs/http/ngx_http_autoindex_module.html)
- [Zulip Docker Compose](https://github.com/zulip/docker-zulip/blob/main/compose.yaml)
- [Valkey CLI](https://valkey.io/topics/cli/)
- [Dify 1.20.0 release](https://github.com/langgenius/dify/releases/tag/1.20.0)
- [Dify Agent guide](https://github.com/langgenius/dify/blob/main/dify-agent/docs/dify-agent/guide/index.md)
- [Dify Docker deployment](https://github.com/langgenius/dify/blob/main/docker/README.md)
- [GitLab installation requirements](https://docs.gitlab.com/install/requirements/)
- [GitLab in Docker](https://docs.gitlab.com/install/docker/installation/)
- [GitLab in a memory-constrained environment](https://docs.gitlab.com/omnibus/settings/memory_constrained_envs/)
