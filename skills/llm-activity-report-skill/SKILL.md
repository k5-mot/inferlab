---
name: llm-activity-report-skill
description: Open WebUI Channelsの投稿と必要に応じたLangfuse情報から、日本語で活動レポートを作成する。
version: 1.0.0
author: inferlab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Reporting, Activity, Open WebUI, Langfuse]
---
# llm-activity-report-skill

## 目的

Open WebUI Channelsの指定期間内の投稿をもとに、日本語で活動レポートを作成する。レポートでは、誰が何をしたか、何が変わったか、どのリスクやブロッカーが出たか、次に何を確認すべきかを整理する。

## 手順

1. `open-webui-skill` を使って対象チャンネルの投稿を取得する。
2. 人間とAIの投稿を区別せず、どちらも活動内容として扱う。
3. 必要に応じてスレッド返信も含める。
4. 添付ファイルが重要な場合は、`open-webui-skill` でファイル内容を取得する。
5. Langfuseの認証情報やトレースが利用できる場合は、モデル/ツール利用、エラー、コスト、注目トレースを加味する。利用できない場合は、その旨を日本語で明記する。
6. Markdown本文は必ず日本語で作成する。固有名詞、チャンネル名、ユーザー名、コード、ログ断片は原文を保持してよい。

## 補助コマンド

```bash
python3 /opt/inferlab/skills/llm-activity-report-skill/report.py \
  --channel report \
  --since "2026-04-28T00:00:00+09:00" \
  --until "2026-04-28T23:59:59+09:00" \
  --limit 200
```

この補助コマンドは `open-webui-skill` 経由で投稿を取得し、日本語のベースラインレポートを整形する。

## 出力形式

ユーザーから別指定がない限り、以下の日本語構成を使う。

```markdown
## LLM活動レポート - {period}

### サマリー
- ...

### ユーザー別アクティビティ
- ...

### AI / ツール活動
- ...

### ファイル / 成果物
- ...

### リスク / ブロッカー
- ...

### 推奨フォローアップ
1. ...
```

## 連携

投稿する場合は、生成したMarkdownを `open-webui-skill` に渡す。

```bash
python3 /opt/inferlab/skills/open-webui-skill/client.py post \
  --channel report \
  --file ./activity_report.md
```
