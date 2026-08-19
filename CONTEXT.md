# Inferlab

Inferlabは、社内向けLLM基盤と周辺サービスを組み合わせて、知識管理、推論、開発支援の運用環境を構成するための文脈である。

## Language

**設定源**:
システムの動作設定を宣言的に管理する単一の入口。credential本体は含めず、secret storeまたは環境変数への参照だけを持つ。
_Avoid_: 設定ファイル, config, 環境変数設定

**知識コンパイル**:
OpenKBが取り込み済み資料をもとにLLM Wikiのページ、リンク、要約、矛盾情報を再構成する処理。高頻度の取り込みとは独立した周期で実行する。
_Avoid_: compile, 再生成, Wiki生成

**取り込み**:
Source Systemから差分を取得し、Canonical Documentへ正規化してOpenKB投入待ちとしてstagingするまでの処理。OpenKBの現行APIでは投入とdocument compileを分離できないため、実際のOpenKB addは知識コンパイル開始時に行う。LLM Wikiの再構成やBookStackへの公開は含めない。
_Avoid_: ingest, クロール, 同期

**公開**:
OpenKB上のGenerated WikiをBookStackのLLM Wikiへ反映する処理。Human Wikiへの書き込みや外部sourceへの書き戻しは含めない。
_Avoid_: publish, 同期, 反映
