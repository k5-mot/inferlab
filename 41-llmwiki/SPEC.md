# LLM Wiki 基盤 基本設計書

## 1. 目的

本システムは、社内に分散する情報を継続的に取り込み、LLM が再利用できる引用追跡可能な Wiki へコンパイルする。

Knowledge Compiler と Presentation System には `llm-wiki-compiler` を使用する。独自実装は、定期実行とコンテナ公開に必要な薄い運用層へ限定する。

## 2. MVP スコープ

初期 MVP は次を実現しなければならない（MUST）。

- `llm-wiki-compiler` の `ingest` で URL またはファイルを `sources/` へ取り込む。
- `llm-wiki-compiler` の `compile` で `sources/` を `wiki/` へ増分コンパイルする。
- `llm-wiki-compiler` の `view` で生成 Wiki を閲覧する。
- ingest と compile の実行時刻を `config.yaml` で設定する。
- source 共通の ingest 既定値と source 別 override を `config.yaml` で設定する。
- provider、chat/embedding model、出力言語、並列数、review mode、viewer を `config.yaml` で設定する。
- 設定はコンテナ起動時に一度だけ読み込む。変更時はコンテナを再起動する。

初期 MVP は次を実装してはならない（MUST NOT）。

- OpenKB を Knowledge Compiler として併用する。
- 生成 Wiki を Wiki.js へ publish する。
- GitLab、Zulip、Nextcloud、Wiki.js、Kaneo 固有の API client を compiler process に組み込む。
- 生成内容の validation gate を有効化する。

validation は将来の拡張対象とする。`llmwiki lint`、`llmwiki eval`、review policy を組み合わせる設計を別途定義するまで、自動 publish の可否判定には使用しない。

## 3. アーキテクチャ

```text
Source System / File / URL
          |
          | llmwiki ingest または外部 producer
          v
  sources/*.md
          |
          | llmwiki compile
          v
  wiki/*.md + .llmwiki/*
          |
          | llmwiki view
          v
  Read-only Viewer :34100
```

コンテナ内の構成は次とする。

```text
llmwiki-runner
  |- Config Loader
  |- Cron Scheduler
  |- llmwiki CLI 1.1.0
  |- llmwiki Viewer (127.0.0.1 only)
  `- Viewer Proxy (0.0.0.0:8080)
```

`llmwiki view` は wildcard address への bind を拒否する。runner は viewer を loopback で起動し、同一 process 内の read-only proxy を通して Compose の port へ公開しなければならない（MUST）。proxy は upstream viewer の Host/Origin 検査を通過させるため、upstream 側へ送る request header を loopback origin に正規化しなければならない（MUST）。

viewer は起動時 snapshot を保持する。runner は compile 成功後に viewer process を再起動し、新しい Wiki を表示しなければならない（MUST）。

## 4. データ契約

project root は次の layout を維持しなければならない（MUST）。

```text
project/
  sources/
  wiki/
  .llmwiki/
  artifacts/
  log.md
```

外部 source-system adapter は独立した producer とし、`llm-wiki-compiler` の `sources/` Input Contract に従う Markdown を `sources/` へ出力しなければならない（MUST）。compiler は元の API へ到達してはならない（MUST NOT）。

各 source file は `title`、`source`、`ingestedAt` を frontmatter に持たなければならない（MUST）。source の更新判定と ownership は upstream の `.llmwiki/state.json` に委譲する。

## 5. 設定

`config.yaml` は次を唯一の運用設定とする。

- project root
- timezone
- source 共通 ingest 設定
- source ごとの input、enabled、ingest override
- compile schedule、ingest 後 compile、並列数、review mode
- chat/embedding provider、model、API endpoint、credential 環境変数名
- 出力言語
- viewer の内部 port、公開 address、起動 timeout

credential の値は `config.yaml` へ直接書いてはならない（MUST NOT）。`credential_env` には環境変数名だけを記述する。

未知の設定項目、無効な cron、未対応 provider、必要 credential の欠落は起動失敗にしなければならない（MUST）。一部だけを既定値で補って起動してはならない（MUST NOT）。

## 6. Scheduling

source ごとの実効 ingest 設定は、`defaults.ingest` に `sources[].ingest` を上書きして決定する。

同一コンテナ内の ingest と compile は直列化しなければならない（MUST）。前の job が実行中の場合、後続 job は待機する。source ingest が成功し、`compile.on_ingest` が有効な場合は同じ job 内で増分 compile を実行する。

schedule はコンテナ再起動後の次回該当時刻から実行する。起動直後の自動 ingest または compile は行わない。

## 7. 障害時動作

- ingest 失敗時は compile-on-ingest を実行してはならない（MUST NOT）。
- compile 失敗時は既存 viewer を停止してはならない（MUST NOT）。
- compile 成功後の viewer 再起動に失敗した場合、container health を unhealthy にしなければならない（MUST）。
- 個別 scheduled job の失敗で runner process を終了してはならない（MUST NOT）。次回 schedule を継続する。
- config 読込、provider 設定、viewer 初回起動、proxy bind の失敗時は process を終了しなければならない（MUST）。

## 8. セキュリティ

- viewer は read-only とし、runner 独自の write API を提供してはならない（MUST NOT）。
- API key を log、Wiki、source file へ出力してはならない（MUST NOT）。
- `sources/`、`wiki/`、`.llmwiki/` は単一の named volume に保存する。
- host へ公開するのは viewer proxy の port だけとする。

## 9. 将来拡張

次は初期 MVP 外とする。

- source-system 固有 producer の追加
- MCP server の常駐公開
- validation、lint、eval による quality gate
- review candidate の承認 UI
- authentication gateway
- static export と外部 publish

## References

- [llm-wiki-compiler](https://github.com/atomicstrata/llm-wiki-compiler)
- [Viewer CLI](https://github.com/atomicstrata/llm-wiki-compiler/blob/v1.1.0/docs/cli/view.mdx)
- [Compile CLI](https://github.com/atomicstrata/llm-wiki-compiler/blob/v1.1.0/docs/cli/compile.mdx)
- [sources Input Contract](https://github.com/atomicstrata/llm-wiki-compiler/blob/v1.1.0/SOURCES_CONTRACT.md)
