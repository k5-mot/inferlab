---
name: tech-news-report-skill
description: 生成AI、クラウド、FinOps、ツールなどの最新技術ニュースを調査し、日本語でレポートする。
version: 1.0.0
author: inferlab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [News, Research, Generative AI, Cloud, FinOps]
---
# tech-news-report-skill

## 目的

生成AI、クラウド、FinOps、開発ツール、インフラ、セキュリティ、周辺エコシステムの変化を調査し、日本語の技術ニュースレポートを作成する。

## 最新性ルール

ニュースは変化が速いため、レポート作成前に必ずweb/searchを使って最新情報を確認し、出典リンクを含める。できるだけ一次情報や信頼できる情報源を優先する。

- ベンダーブログ、リリースノート
- クラウドプロバイダーの公式発表
- FinOps Foundationや公式プロジェクトの発表
- ツールのGitHub releases
- 標準化団体やセキュリティアドバイザリ
- 補助情報として信頼できる技術メディア

## 手順

1. ひとつのベンダーに偏らず、複数ソースを横断して調査する。
2. 指定期間内のニュースを優先する。期間指定がなければ直近24から72時間を目安にする。
3. 同じ話題の重複を整理する。
4. 各項目について、タイトル、出典、URL、日付、概要、重要ポイントを押さえる。
5. Markdown本文は必ず日本語で作成する。製品名、サービス名、リリース名、引用が必要な短い原文は原文のままでもよい。
6. 投稿が必要な場合は `open-webui-skill` で最終Markdownを投稿する。

## 補助フォーマッター

web/searchでニュース項目を集めた後、JSON項目を以下で日本語Markdownに整形できる。

```bash
python3 /opt/inferlab/skills/tech-news-report-skill/report.py \
  --items-json '[{"title":"Example","source":"Vendor blog","url":"https://example.com","summary":"...","impact":"..."}]'
```

## 出力形式

```markdown
## 技術ニュースレポート

### エグゼクティブサマリー
- ...

### 生成AI
1. ...

### クラウド / インフラ
1. ...

### FinOps / コスト
1. ...

### ツール / 開発者ワークフロー
1. ...

### 推奨アクション
1. ...

### 出典
- ...
```

## 連携

投稿する場合:

```bash
python3 /opt/inferlab/skills/open-webui-skill/client.py post \
  --channel report \
  --file ./tech_news_report.md
```
