# Inferlab

Inferlabは、社内向けLLM基盤と周辺サービスを組み合わせて、知識管理、推論、開発支援の運用環境を構成するための文脈である。

## Language

**設定源**:
システムの動作設定を宣言的に管理する単一の入口。credential本体は含めず、secret storeまたは環境変数への参照だけを持つ。
_Avoid_: 設定ファイル, config, 環境変数設定

**知識コンパイル**:
llm-wiki-compilerが`sources/`の変更をもとに、引用追跡可能なpage、link、metadataを`wiki/`へ増分生成する処理。取り込みとは独立した周期で実行できる。
_Avoid_: compile, 再生成, Wiki生成

**取り込み**:
URLまたはfileをllm-wiki-compilerの`sources/` Input Contractへ変換し、`sources/`へ保存するまでの処理。知識コンパイルとviewer更新は含めない。Source System固有の処理は独立producerが所有する。
_Avoid_: ingest, クロール, 同期

**閲覧**:
llm-wiki-compilerが生成した`wiki/`を内蔵read-only viewerで検索、参照、graph表示する処理。Wiki内容の編集、外部Wikiへの転記、Source Systemへの書き戻しは含めない。
_Avoid_: viewer, publish, 公開
