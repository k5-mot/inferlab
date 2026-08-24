# LLM Wiki 基盤 基本設計書

## 1. 目的

本システムは、社内に分散する情報を継続的に取り込み、LLM が再利用できる引用追跡可能な Wiki へコンパイルする。

Knowledge Compiler と Presentation System には `llm-wiki-compiler` を使用する。独自実装は、定期実行とコンテナ公開に必要な薄い運用層へ限定する。

## 2. MVP スコープ

初期 MVP は次を実現しなければならない（MUST）。

- source adapterを通じてURL、ファイル、CouchDB LiveSync snapshotを`sources/`へ取り込む。
- `llm-wiki-compiler` の `compile` で `sources/` を `wiki/` へ増分コンパイルする。
- compile成功後に`llmwiki lint`と`llmwiki eval`を実行し、診断結果を保存する。
- `llm-wiki-compiler` の `view` で生成 Wiki を閲覧する。
- `llm-wiki-compiler` の `serve` をstdio MCP serverとして利用できるようにする。
- Viewer/MCP実行環境とIngesterを別containerにし、project volume以外の責務を共有しない。
- ingest と compile の実行時刻を `config.yaml` で設定する。
- source 共通の ingest 既定値と source 別 override を `config.yaml` で設定する。
- provider、chat/embedding model、出力言語、並列数、review mode、viewer を `config.yaml` で設定する。
- 設定はコンテナ起動時に一度だけ読み込む。変更時はコンテナを再起動する。

初期 MVP は次を実装してはならない（MUST NOT）。

- OpenKB を Knowledge Compiler として併用する。
- 生成 Wiki を Wiki.js へ publish する。
- adapterからOKF importで`wiki/`へ直接pageを書き込む。
- GitLab、Zulip、Nextcloud、Wiki.js、Kaneo固有のclientをcompiler processへ組み込む。
- 生成内容の validation gate を有効化する。

validation は将来の拡張対象とする。`llmwiki lint`、`llmwiki eval`、review policy を組み合わせる設計を別途定義するまで、自動 publish の可否判定には使用しない。

## 3. アーキテクチャ

```text
Source System / File / URL / CouchDB
          |
          | llmwiki-ingester / Source Adapter Registry
          v
 shared volume: sources/*.md
          |
          | llmwiki-ingester / llmwiki compile -> lint -> eval
          v
 shared volume: wiki/*.md + .llmwiki/*
          |
          | llmwiki runtime / view + serve
          v
  Read-only Viewer :34100
```

container構成は次とする。

```text
llmwiki
  |- llmwiki Viewer (127.0.0.1 only)
  |- Viewer Proxy (0.0.0.0:8080)
  |- Viewer Generation Monitor
  `- llmwiki serve stdio wrapper

llmwiki-ingester
  |- Config Loader / Cron Scheduler
  |- Source Adapter Registry
  |    |- Input Adapter
  |    `- CouchDB LiveSync Adapter -> sources/*.md
  |- llmwiki CLI 1.1.0
  `- ingest -> compile -> lint -> eval

llmwiki-project named volume
  `- sources/ + wiki/ + .llmwiki/ + artifacts/
```

`llmwiki view`はwildcard addressへのbindを拒否する。Runtimeはviewerをloopbackで起動し、同一process内のread-only proxyを通してComposeのportへ公開しなければならない（MUST）。proxyはupstream viewerのHost/Origin検査を通過させるため、upstream側へ送るrequest headerをloopback originに正規化しなければならない（MUST）。

viewerは起動時snapshotを保持する。Ingesterはcompile成功後に共有volumeのgeneration markerを更新しなければならない（MUST）。Runtimeはmarker変更を検知してviewer processを再起動し、新しいWikiを表示しなければならない（MUST）。

`llmwiki serve`はstdio transportであるため、Runtimeの常駐TCP portとして公開してはならない（MUST NOT）。MCP clientは`docker exec -i`を通じてRuntime container内に接続ごとのserve processを起動しなければならない（MUST）。

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

source-system固有実装は、Ingesterの共通source adapter interfaceを実装しなければならない（MUST）。schedulerはsource種別を判定せず、registryへ正規化済みsource設定を渡さなければならない（MUST）。adapterは`llm-wiki-compiler`の`sources/` Input Contractに従うMarkdownを`sources/`へ出力し、compilerとRuntimeは元のAPIへ到達してはならない（MUST NOT）。

CouchDB adapterはSelf-hosted LiveSyncの非削除Markdown親documentを対象とし、親documentの`children`順にleaf chunkを連結しなければならない（MUST）。hidden path、`exclude_path_prefixes`に一致するpath、Markdown以外のdocumentを取り込んではならない（MUST NOT）。前回snapshotから消えたdocumentについては、adapter自身が所有するsource fileだけを削除しなければならない（MUST）。`title_strategy`が`hierarchy`の場合は末尾のMarkdown拡張子を除去し、vault rootからnoteまでの全path要素を空白で連結した値をsource titleにしなければならない（MUST）。階層名の重複は保持しなければならない（MUST）。

各 source file は `title`、`source`、`ingestedAt` を frontmatter に持たなければならない（MUST）。adapter は自身のmanifestでsource fileのownershipと削除を管理し、本文と安定metadataが同一の場合はfileを書き換えてはならない（MUST NOT）。compilerによる増分compileの状態はupstreamの`.llmwiki/state.json`へ委譲する。

## 5. 設定

`config.yaml` は次を唯一の運用設定とする。

- project root
- timezone
- source 共通 ingest 設定
- sourceごとのadapter、接続設定、title生成方式、enabled、ingest override
- compile schedule、ingest 後 compile、並列数、review mode
- chat/embedding provider、model、API endpoint、credential 環境変数名
- 出力言語
- lintの有効化、evalの有効化とsuite
- viewer の内部 port、公開 address、起動 timeout
- viewer generation markerのpoll間隔

credential の値は `config.yaml` へ直接書いてはならない（MUST NOT）。`credential_env` には環境変数名だけを記述する。

未知の設定項目、無効な cron、未対応 provider、必要 credential の欠落は起動失敗にしなければならない（MUST）。一部だけを既定値で補って起動してはならない（MUST NOT）。

## 6. Scheduling

source ごとの実効 ingest 設定は、`defaults.ingest` に `sources[].ingest` を上書きして決定する。

Ingester内のingest、compile、lint、evalは直列化しなければならない（MUST）。前のjobが実行中の場合、後続jobは待機する。source ingestが成功し、`compile.on_ingest`が有効な場合は同じjob内で増分compile、lint、evalを順番に実行する。lintまたはevalの診断結果は初期MVPのvalidation gateに使用してはならない（MUST NOT）。

schedule はコンテナ再起動後の次回該当時刻から実行する。起動直後の自動 ingest または compile は行わない。

## 7. 障害時動作

- ingest 失敗時は compile-on-ingest を実行してはならない（MUST NOT）。
- compile失敗時はlintとevalを実行してはならない（MUST NOT）。
- compile 失敗時は既存 viewer を停止してはならない（MUST NOT）。
- compile 成功後の viewer 再起動に失敗した場合、container health を unhealthy にしなければならない（MUST）。
- 個別scheduled jobの失敗でIngester processを終了してはならない（MUST NOT）。次回scheduleを継続する。
- config 読込、provider 設定、viewer 初回起動、proxy bind の失敗時は process を終了しなければならない（MUST）。

## 8. セキュリティ

- viewerはread-onlyとし、Runtime独自のwrite APIを提供してはならない（MUST NOT）。
- API key を log、Wiki、source file へ出力してはならない（MUST NOT）。
- `sources/`、`wiki/`、`.llmwiki/`、`artifacts/`は単一のnamed volumeに保存する。
- RuntimeとIngesterはproject named volume以外のfilesystemを共有してはならない（MUST NOT）。
- host へ公開するのは viewer proxy の port だけとする。

## 9. 将来拡張

次は初期 MVP 外とする。

- GitLab、Zulip、Nextcloudなどのsource adapter追加
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
- [MCP Server](https://github.com/atomicstrata/llm-wiki-compiler/blob/v1.1.0/docs/cli/serve.mdx)
- [Open Knowledge Format](https://github.com/atomicstrata/llm-wiki-compiler/blob/v1.1.0/docs/guides/open-knowledge-format.mdx)
