# ローカル実行環境

複数の機能を Docker Compose profile で分けて起動するための構成です。

![構成図](docs/assets/DIAGRAM.svg)

## 起動手順

通常はラッパースクリプトで標準 profile を順番に起動します。

```bash
# 標準 profile を順番に起動する。
sudo ./dc.sh up --remove-orphans
```

期待結果:

- 標準 profile のコンテナが起動する。
- 主要コンテナが `running` または `healthy` になる。

失敗条件:

- Compose 設定の解決に失敗する。
- 必須コンテナが `unhealthy` になる。

初回設定は [docs/INITIAL_SETUP.md](docs/INITIAL_SETUP.md) を参照してください。

## 一括起動

すべての標準 profile を 1 回の Compose 実行にまとめる場合は、次のコマンドを使います。

```bash
# 標準 profile を 1 つの Compose 実行で起動する。
sudo ./dc.sh up-full --remove-orphans
```

期待結果:

- 標準 profile のコンテナがまとめて起動する。
- 主要コンテナが `running` または `healthy` になる。

失敗条件:

- Compose 設定の解決に失敗する。
- コンテナ間の依存関係を満たせない。

## Profile

| Profile | Compose file | 用途 |
| --- | --- | --- |
| `common` | `00-common/docker-compose.yml` | 共通入口と認証 |
| `infra` | `01-infra/docker-compose.yml` | 外部接続と基盤 |
| `inference` | `10-inference/docker-compose.yml` | 推論、埋め込み、エージェント |
| `webui` | `11-webui/docker-compose.yml` | Web UI、検索、音声、ベクトル検索 |
| `storage` | `12-storage/docker-compose.yml` | ファイル保存と知識ベース |
| `automation` | `13-automation/docker-compose.yml` | 自動化 |
| `team-chat` | `20-team-chat/docker-compose.yml` | チャット |
| `team-project` | `21-team-project/docker-compose.yml` | プロジェクト管理 |
| `team-wiki` | `22-team-wiki/docker-compose.yml` | Wiki |
| `team-git` | `23-team-git/docker-compose.yml` | Git 管理 |
| `developer` | `30-developer/docker-compose.yml` | 開発用パッケージ配布 |
| `o11y` | `50-o11y/docker-compose.yml` | 監視 |
| `llmops` | `51-llmops/docker-compose.yml` | LLM 観測 |

GPU 監視用 profile は任意です。対応するホストで、監視用 Compose と設定ファイルの該当コメントを解除して使います。

## 個別起動

監視 profile だけを起動する例です。

```bash
# 監視 profile だけを起動する。
sudo docker compose --env-file .env --profile o11y up -d
```

期待結果:

- 監視用 Web UI が指定ポートで応答する。
- メトリクス収集用のエンドポイントが応答する。

失敗条件:

- 監視用コンテナが `unhealthy` になる。
- 設定ファイルを読み込めない。

## オフライン用イメージ保存

現在の Compose 構成で使うイメージを保存する場合は、次のコマンドを使います。

```powershell
# 現在の Compose 構成で使うイメージを保存する。
pwsh -NoProfile -File script/download-stack-images.ps1
```

期待結果:

- `images/` に対象イメージごとの `.tar` が作成される。

失敗条件:

- 必要な取得コマンドが見つからない。
- いずれかのイメージ取得に失敗する。
