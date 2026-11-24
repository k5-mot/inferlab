# LLM WikiへのCouchDB source追加

## Why

Obsidian Self-hosted LiveSyncのCouchDB dataを、既存sourceを壊さずLLM Wikiへ一方向に取り込む経路が必要でした。

## What Changed

- CouchDB snapshotをread-onlyで復元するsource adapterを追加しました。
- adapter所有fileをmanifestで追跡し、削除を安全に収束させました。
- 同期成功後だけ知識コンパイルを開始する失敗境界を定義しました。

## Archived Contract

この変更で採用した設計は同じarchive内の[設計記録](design.md)、data形式の分析は[調査記録](research.md)に保存します。現行構成からLLM Wikiは削除済みであり、運用手順は提供しません。
