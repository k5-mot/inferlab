---
name: tech-news-report-skill
description: 生成AI、クラウド、FinOps、ツールなどの最新技術ニュースを調査し、日本語でレポートする。
version: 1.1.2
author: inferlab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [News, Research, Generative AI, Cloud, FinOps]
    mcp_servers: [rss]
---
# tech-news-report-skill

## 目的

生成AI、クラウド、FinOps、開発ツール、インフラ、セキュリティ、周辺エコシステムの変化を調査し、日本語の技術ニュースレポートを作成する。

## ニュース取得ツール

ニュースの取得には `mcp_rss_get_feed` ツール（rss-mcp MCP サーバー）を使う。curl・wget は使わない。

主要フィード一覧:

| カテゴリ | フィード URL |
|---|---|
| OpenAI ブログ | `https://openai.com/blog/rss.xml` |
| Google AI ブログ | `https://blog.research.google/feeds/posts/default` |
| AWS ニュース | `https://aws.amazon.com/blogs/aws/feed/` |
| Google Cloud ブログ | `https://cloudblog.withgoogle.com/rss/` |
| Azure ブログ | `https://azure.microsoft.com/en-us/blog/feed/` |
| GitHub ブログ | `https://github.blog/feed/` |
| Hacker News トップ | `https://hnrss.org/frontpage` |

各フィードは `count` パラメータで取得件数を指定できる（デフォルト1、0で全件）。

## 最新性ルール

ニュースは変化が速いため、レポート作成前に必ず `mcp_rss_get_feed` で最新フィードを取得し、出典リンクを含める。できるだけ一次情報や信頼できる情報源を優先する。

- ベンダーブログ、リリースノート
- クラウドプロバイダーの公式発表
- FinOps Foundationや公式プロジェクトの発表
- ツールのGitHub releases
- 標準化団体やセキュリティアドバイザリ
- 補助情報として信頼できる技術メディア

## 手順

1. `mcp_rss_get_feed` を使って上記の主要フィードから最新記事を取得する。一度に複数フィードをまとめて呼ぶ。
2. ひとつのベンダーに偏らず、複数ソースを横断して調査する。
3. 指定期間内のニュースを優先する。期間指定がなければ直近24から72時間を目安にする。
4. 同じ話題の重複を整理する。
5. 各項目について、タイトル、出典、URL、日付、概要、重要ポイントを押さえる。
6. Markdown本文は必ず日本語で作成する。製品名、サービス名、リリース名、引用が必要な短い原文は原文のままでもよい。
7. 投稿が必要な場合は `open-webui-skill` で最終Markdownを投稿する。

## 補助フォーマッター

収集したニュース項目をJSON配列にまとめた後、以下で下記の出力形式に準拠した日本語Markdownへ整形できる。

```bash
python3 /opt/inferlab/skills/tech-news-report-skill/report.py \
  --items-json '[{"title":"Example","source":"Vendor blog","url":"https://example.com","summary":"...","impact":"..."}]'
```

## 出力形式

`<ジャンル>` はニュースの種類ではなく、生成AI・FinOps・Cloud・Developer Tools・Security などの技術領域を示すラベルとして使う。

```markdown
---
## 技術ニュースレポート (YYYY-MM-DD)

- 📝 <ここに活動の全体的な傾向や重要なポイントを3行程度でまとめる>

### 🔥 本日の主要ニュース

#### 1. <ジャンル>: <ニュースAのタイトル>
- URL：<ニュースAのURL>
- 概要：<ニュースAの内容を日本語で説明する。>
- 重要ポイント：<ニュースAの重要なポイントを3行程度でまとめる。>

#### 2. <ジャンル>: <ニュースBのタイトル>
- URL：<ニュースBのURL>
- 概要：<ニュースBの内容を日本語で説明する。>
- 重要ポイント：<ニュースBの重要なポイントを3行程度でまとめる。>

#### 3. ...
```

## 連携

投稿する場合:

```bash
python3 /opt/inferlab/skills/open-webui-skill/client.py post \
  --channel report \
  --file ./tech_news_report.md
```
