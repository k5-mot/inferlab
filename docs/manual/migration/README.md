# Migration manual

serviceごとのdata migrationとmajor version upgradeをまとめる。すべてのcommandはrepository rootで実行する。

| Service | 対象 | 状態 |
| --- | --- | --- |
| [OpenClaw](OPENCLAW.md) | state、SQLite、managed config、plugin | `2026.11.7`への移行を実施済み |
| [Kaneo](KANEO.md) | PostgreSQL 16から18、Kaneo schema | PostgreSQL 18とKaneo 2.50.0への移行を実施済み |
| [Zulip](ZULIP.md) | Redis 8 RDBからValkey 9 | 手順確定、未実施 |
| [Dify](DIFY.md) | PostgreSQL、file storage、cache | 手順確定 |
| [Nextcloud](NEXTCLOUD.md) | Nextcloud 34から35 | 手順確定、未実施 |
| [Verdaccio](VERDACCIO.md) | Verdaccio 6から7 | 手順確定、未実施 |
| [RAGFlow](RAGFLOW.md) | RAGFlow 0.xから1.x | 0.27.3の公式経路待ち |
| [OpenSearch](OPENSEARCH.md) | OpenSearch 2.19から3.x | RAGFlowとは別作業で実施 |

各manualの事前条件、backup、期待結果、失敗条件、rollbackをすべて満たすまで旧volumeを削除してはならない（MUST NOT）。
