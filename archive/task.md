# RAGFlow統合ナレッジ検索・文書生成基盤 仕様書

## 1. 概要

本システムは、セルフホスト環境上で以下を実現する。

* BookStack / Seafile を統合データソースとしたRAG検索
* Hybrid Search（全文 + ベクトル）
* Parent/Child Chunking
* Reranking
* 構造化出力
* CarboneによるDOCX/PDF生成
* ComfyUIによる図版生成
* 全文書・成果物の統合管理

---

# 2. システム目的

## 2.1 主目的

社内知識・業務文書・添付資料を横断検索し、LLMを用いて：

* 回答生成
* レポート生成
* 提案書生成
* 手順書生成

を自動化する。

---

# 3. 全体アーキテクチャ

```text
BookStack ─┐
           │
           ▼
      Sync Worker
           │
Seafile ───┘
           │
           ▼
        RAGFlow
           │
 ┌─────────┼─────────┐
 ▼         ▼         ▼
Elastic  Redis     MySQL
Search
           │
           ▼
      SeaweedFS(S3)
           │
           ▼
      Structured JSON
           │
     ┌─────┴─────┐
     ▼           ▼
 ComfyUI      Carbone
     │           │
     └─────┬─────┘
           ▼
       DOCX/PDF
           │
           ▼
       Seafile
```

---

# 4. 採用技術スタック

| 領域          | 技術                                    |
| ----------- | ------------------------------------- |
| Wiki        | BookStack                             |
| ファイル管理      | Seafile                               |
| RAG基盤       | RAGFlow                               |
| 検索エンジン      | Elasticsearch                         |
| キャッシュ/ジョブ   | Redis                                 |
| メタDB        | MySQL                                 |
| オブジェクトストレージ | SeaweedFS                             |
| 文書生成        | Carbone                               |
| 図版生成        | ComfyUI                               |
| API/同期      | Python + FastAPI                      |
| バックグラウンド処理  | Celery                                |
| スケジューラ      | APScheduler                           |
| コンテナ        | Docker Compose / Kubernetes(Optional) |

---

# 5. データソース仕様

## 5.1 BookStack

### 役割

構造化ナレッジ管理。

### 対象

* 手順書
* FAQ
* 運用ルール
* 設計思想
* 業務ナレッジ

### 取得方法

BookStack REST API。

### 取得対象

| エンティティ  | 用途           |
| ------- | ------------ |
| Shelf   | 業務カテゴリ       |
| Book    | 業務単位         |
| Chapter | Parent Chunk |
| Page    | Child Chunk  |

---

## 5.2 Seafile

### 役割

原本・業務ファイル管理。

### 対象

* PDF
* DOCX
* XLSX
* PPTX
* 画像
* 議事録
* 契約書
* 添付資料

### 取得方法

Seafile REST API。

### 同期単位

* Library
* Directory
* File

---

# 6. Sync Worker仕様

## 6.1 役割

RAGFlow投入前のETL・同期制御レイヤ。

---

## 6.2 主機能

### 差分同期

判定条件：

* updated_at
* hash
* version

---

### 正規化

| 元形式  | 正規化           |
| ---- | ------------- |
| HTML | Markdown      |
| DOCX | Text/Markdown |
| PDF  | OCR/Text      |
| XLSX | CSV/Text      |
| PPTX | Text          |

---

### Metadata付与

例：

```json
{
  "source": "bookstack",
  "department": "engineering",
  "approval_status": "approved"
}
```

---

### RAGFlow投入

* Dataset作成
* File Upload
* Parse実行
* Reindex

---

# 7. RAGFlow仕様

## 7.1 検索方式

### Hybrid Retrieval

併用：

* Keyword Search
* Vector Search

---

## 7.2 Rerank

有効。

### 用途

* ノイズ低減
* FAQ精度向上
* 長文検索精度向上

---

## 7.3 Parent/Child Chunking

### BookStack

| Chunk  | 単位                |
| ------ | ----------------- |
| Parent | Chapter           |
| Child  | Section/Paragraph |

### Seafile

| Chunk  | 単位             |
| ------ | -------------- |
| Parent | Document       |
| Child  | Page/Paragraph |

---

## 7.4 Metadata Filter

対応項目：

* source
* department
* tag
* approval_status
* updated_at

---

## 7.5 Citation

必須。

保持項目：

* page_url
* file_path
* source_name

---

# 8. Elasticsearch仕様

## 8.1 用途

* 全文検索
* BM25
* Hybrid Retrieval
* Metadata Filter

---

## 8.2 Index設計

インデックス分離：

| Index         | 用途                 |
| ------------- | ------------------ |
| rag_bookstack | Wiki               |
| rag_seafile   | 原本                 |
| rag_generated | 承認済み生成文書(Optional) |

---

# 9. SeaweedFS仕様

## 9.1 用途

S3互換オブジェクトストレージ。

---

## 9.2 格納対象

* RAGFlow Upload
* Parse中間ファイル
* ComfyUI生成画像
* Carbone生成成果物
* 一時JSON

---

# 10. ComfyUI仕様

## 10.1 用途

図版生成専用。

---

## 10.2 対象

* 表紙画像
* 業務フロー図
* 概念図
* インフォグラフィック

---

## 10.3 禁止事項

* 事実生成
* データ推論
* 根拠生成

---

# 11. Carbone仕様

## 11.1 用途

構造化JSONからDOCX/PDF生成。

---

## 11.2 入力

```json
{
  "title": "...",
  "summary": "...",
  "sections": [],
  "citations": []
}
```

---

## 11.3 出力

* DOCX
* PDF

---

# 12. Seafile成果物管理

## 12.1 保存対象

* 承認済み成果物
* 配布用PDF
* DOCX

---

## 12.2 非対象

* 中間JSON
* 一時画像
* 一時成果物

---

# 13. ACL/権限制御

## 13.1 基本方針

RAGFlow側でmetadata filterによる制御。

---

## 13.2 推奨

Dataset分離：

* engineering
* hr
* sales
* public

---

# 14. ログ・監査

## 14.1 保存対象

* 検索Query
* 使用Chunk
* Citation
* 生成Prompt
* 生成文書

---

# 15. バックアップ

## 15.1 対象

| 対象            | 方法                |
| ------------- | ----------------- |
| MySQL         | dump              |
| Elasticsearch | snapshot          |
| SeaweedFS     | volume backup     |
| Seafile       | filesystem backup |
| BookStack     | DB backup         |

---

# 16. 非機能要件

## 16.1 可用性

* Redis persistence enabled
* Elasticsearch replica optional
* SeaweedFS volume replication optional

---

## 16.2 性能

目標：

| 項目     | 目標     |
| ------ | ------ |
| 検索応答   | 3〜10秒  |
| 文書生成   | 10〜60秒 |
| 再index | 非同期    |

---

## 16.3 セキュリティ

* Internal Network Only
* HTTPS Required
* API Key Rotation
* Audit Logging

---

# 17. PoCスコープ

## Phase 1

* BookStack同期
* Seafile同期
* RAGFlow検索
* Citation付き回答

---

## Phase 2

* Carbone生成
* DOCX/PDF出力

---

## Phase 3

* ComfyUI図版
* 承認フロー
* ACL強化

---

# 18. 将来拡張

* Agent Workflow
* Knowledge Graph
* Multi-step Retrieval
* Auto Classification
* Approval Pipeline
* Workflow Automation
* Slack/Teams連携
* MCP連携
* Voice Interface
