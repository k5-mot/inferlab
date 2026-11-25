# Open WebUIとOpen TerminalによるOffice作成とPiの構成

## 1. 結論

Open WebUIを業務機能の提供基盤とし、Office文書の作成はOpen Terminal上で行う。用途で次の2つを使い分ける。

| 用途 | 方式 | 社内dataの使い方 |
| --- | --- | --- |
| 標準（Y） | 通常モデル + terminal | Open WebUIの組み込みツール（ナレッジ、ノート、メモリ、チャット検索など）を、ユーザー本人の権限で使う |
| 特化（X） | Pi coding agent | 社内dataには直接触れない。同じチャットで先に通常モデルにRAGで回答させ、モデルをPiへ切り替えると、その回答が会話履歴としてPiへ渡る |

方針は次のとおりである。

- Open WebUIとOpen Terminalには改修を加えない。上流の機能と、派生imageへのファイル追加だけで構成する。上流のバージョン更新に追従できなくなるコストは負わない。
- Open WebUIのAPIキーをOpen Terminalへ置かない。ユーザーごとのキー登録などの手順を不要にする。
- Piなどのエージェントに、独自のKnowledge、Memory、Notesのデータベースを持たせない。Qdrantへも直接アクセスさせない。

ユーザーは、通常モデルを業務アシスタント、Piをコーディングエージェントとして使い分けることで、両者の違いを体験できる。

## 2. 現状（2026-11-25時点で確認済み）

| 項目 | 状態 |
| --- | --- |
| Open WebUI | `v0.13.4`。改修なし。 |
| Open Terminal | `0.17.22`の派生image（`inferlab/open-terminal:0.17.22-pi`）。上流imageへファイルを追加するだけで、改修はしない。 |
| Pi coding agent | `1.6.0`。Open WebUIで`pi/inferlab/...`のモデルとして選べる。 |
| OfficeCLI | `1.0.163`。Word、Excel、PowerPointのSkillを同梱する。 |
| LiteLLM | DBを持たない構成のため、Virtual Keyは発行できない。Master Keyは`llm-broker`だけが持つ。 |
| 本構成の実装 | `feature/add-owui-agent-skills`で実装・検証済み（7章を参照）。 |

## 3. アーキテクチャ

```text
User ─ Keycloak ─ Open WebUI ─┬─ 通常モデル ─ 組み込みツール（本人のセッション、ACL）─ Knowledge / Notes / Memory
                              │      └─ ターミナルツール ─ Open Terminal（ユーザーごとのOSユーザー）─ OfficeCLI
                              └─ Pi（同じチャットの会話履歴を受け取る）─ Open Terminal ─ OfficeCLI
                                                                         └─ llm-broker ─ LiteLLM ─ Langfuse
```

| コンポーネント | 責務 |
| --- | --- |
| Open WebUI | UI、認証、業務データ、RAG、組み込みツール、ターミナルへの中継 |
| Open Terminal | ユーザーごとのOSユーザーでのコマンド実行、ファイル管理、Piの実行 |
| `~/AGENTS.md`、`~/.agents/skills` | 通常モデルとPiが共通で読む指示とSkill。Open Terminalがホームから読み、Open WebUIへ渡す |
| `llm-broker` | LiteLLM Master Keyを保持し、Piへchat completionsとモデル一覧だけを中継する |
| OfficeCLI、`pptx-check` | 成果物の生成、検証、PowerPointのはみ出し検査 |
| LiteLLM、Langfuse | 推論Gateway、トレース |

## 4. 採用しなかった方式と理由

最初は、PiがOpen WebUIのREST APIをAgent Skills経由で呼ぶ方式を実装・検証した。機能としては動いたが、次の理由で採用しなかった。

| 方式 | 不採用の理由 |
| --- | --- |
| Agent Skills + ユーザー別APIキー（`owui-api login`） | ユーザーがキーを発行して登録する手順が必要になる。Piが読めないようにキーを保持するbrokerも必要になる |
| 短期トークンの自動発行 | Open WebUIのJWTはDB上の`session_stamp`と照合される。発行には署名鍵とDBへのアクセスが必要で、内部仕様に依存するため上流の更新に弱い。Open Terminalが乗っ取られた場合の被害も、全ユーザーへ広がる |
| ユーザーセッションの転送（`auth_type: session`） | トークンはOpen Terminalサーバーまでしか届かず、Piへ渡すにはOpen Terminalの改修が必要になる。全権限のトークンをエージェントが持つことにもなる |
| Qdrantへの直接アクセス | Open WebUIは全ユーザーのナレッジとメモリを、マルチテナント方式で共通のコレクションに格納している。ACLを自前で再実装する必要がある。検索自体は既に速く（約0.6秒）、遅いのは埋め込みのため、速度の利点もない |

Open WebUIはエージェントモデルへの依頼を、RAGやフィルターの処理（`process_chat_payload`）より前で分岐させる。そのため、RAGの結果をPiのプロンプトへ直接差し込む方法は無い。一方、新しいPiのセッションは、そのチャットの過去のやり取りを前置きとして受け取る。X方式は、この上流の動作を利用する。

## 5. 権限境界

| 制御 | 実装 |
| --- | --- |
| ユーザーの識別 | Open Terminalのmulti-user modeが、Open WebUIのユーザーごとに別のOSユーザーで実行する。ホームはmode `2770`で、他ユーザーからは読めない |
| 社内data | 通常モデルの組み込みツールは、Open WebUI内でユーザー本人のセッションとACLで動く。PiはOpen WebUIのAPIを呼ばない |
| LiteLLM | Master Keyは`llm-broker`だけが持つ。接続元ソケットの所有uidを`/proc/net/tcp`から得て、OSユーザー名をLangfuseのtrace userに付ける。管理APIは中継しない |
| ホスト権限 | `open-terminal`へ`docker.sock`をマウントしない |
| ターミナルの提供範囲 | `access_grants`に`principal_id: "*"`を指定し、全ユーザーへ提供する |

Open TerminalのOSユーザー分離は、上流の説明どおりsecurity boundaryではない。個人や小規模チームでの利用を前提とし、全社展開や機密業務では、ユーザー別またはタスク別のサンドボックスを使う。

## 6. 指示とSkillの配布

| 配布先 | 方法 |
| --- | --- |
| 新規ユーザー | imageの`/etc/skel`に、`~/AGENTS.md`と`~/.agents/skills`から`/etc/inferlab/agent`へのシンボリックリンクを置く。Open Terminalがユーザーを作るとき（`useradd -m`）にコピーされる |
| 既存ユーザー | `inferlab-entrypoint`が起動時に同じリンクを作る。ユーザーが自分で置いたファイルは上書きしない |
| 更新 | imageを作り直すと、リンク先が変わるため全ユーザーへ反映される |

`AGENTS.md`には、Office作成の検証済み手順（docx、xlsx、pptx、`pptx-check`）を載せる。小さなモデル（gemma4:12b）は手順書に無い作業を誤りやすいため、Skillへ分けずに常にコンテキストへ入る`AGENTS.md`へ置く。

## 7. 検証結果

2026-11-25の検証結果である。詳細は[20-owui/README.md](20-owui/README.md)の「検証結果」を参照する。モデルは`google/gemma4:12b`である。

| 基準 | 状態 |
| --- | --- |
| 通常モデルがナレッジを検索し、出典付きのWordを作れる（Y） | 達成（45秒） |
| 通常モデルがメモリの好みとノートを読み、数式とグラフ付きのExcelを作れる（Y） | 達成（約2分。手順の追加後） |
| 通常モデルのRAGの回答を、同じチャットでPiへ渡してWordを作れる（X） | 達成（要約15秒、Word 45秒） |
| PiがPowerPointを編集可能な図形で作り、はみ出しを検査できる（X） | 達成（`pptx-check`） |
| 他ユーザーのホームやナレッジへアクセスできない | 達成（ホームは`Permission denied`、ナレッジは403） |
| ユーザーのプロセスからLiteLLM Master Keyを読めない | 達成 |
| Langfuseでユーザーごとの推論を確認できる | 達成 |
| ユーザーにキー登録などの追加手順が無い | 達成 |

## 8. 既知の課題

| 優先度 | 課題 | 対応方針 |
| --- | --- | --- |
| P1 | 一般ユーザーが通常モデルを使うには、管理者がモデルを公開する必要がある | 運用で対処する。管理者パネルでモデルをユーザーまたはグループへ公開する |
| P1 | 組み込みツールは、画面から送ったチャット（socket session付き）でだけ有効になる | 上流の仕様。APIからの自動実行には使えない |
| P1 | gemma4:12bは、手順に無い作業を誤り、誤った結果を正しいと報告することがある | 検証済みの手順を`AGENTS.md`へ追加して対処する。成果物はユーザーが確認する |
| P1 | Web検索は、取得ページをCPU版vLLMで埋め込むため1回に10分以上かかる。`RAG_EXTERNAL_RERANKER_URL`はpathが無く、rerankが失敗している | GPUを用意した時点で対処する |
| P2 | Open WebUIは起動時にだけターミナルサーバーを登録する | `open-terminal`の起動後に`open-webui`を再起動する（README） |
| P2 | 閉域環境では、imageのビルド時にnpmとOfficeCLIのバイナリを取得できない | 事前にビルドしたimageを持ち込む |

## 9. 今後の候補

| 候補 | 内容 |
| --- | --- |
| Pi Durable | 数十分から数時間かかる処理や定期実行が必要になった時点で、PoCする（10章） |
| より大きいモデル | gemma4:31bやgpt-oss:20bでの同じシナリオ。試行時は429とツール呼び出し形式の問題があった |
| ユーザー別のLiteLLM利用上限 | 必要になった時点で、LiteLLMにDBを導入してVirtual Keyを発行する |

## 10. Pi Durableの採用検討

### 10.1. Pi Durableとは

`@earendil-works/pi-durable`（1.6.0）は、会話、モデル呼び出し、ツール呼び出しを、画面へ出す前にストレージ（SQLite、JSONLなど）へコミットするエージェントランタイムである。プロセスが途中で落ちても、再オープン時に中断点から再開できる。スリープ（時刻指定の再開）、子タスク、タスクグラフも持つ。

### 10.2. 現行のPi coding agentとの比較

| 観点 | Pi coding agent（現行） | Pi Durable |
| --- | --- | --- |
| 提供形態 | CLI（`pi`）。`pi --mode rpc`を持つ | ライブラリのみ。CLIは無い |
| Open Terminal連携 | ネイティブ対応（`OPEN_TERMINAL_PI_COMMAND`） | 未対応。RPCまたはACPのホストを自作する必要がある |
| API安定性 | 安定版として配布 | READMEで「Experimental. The API changes without notice」と明記 |
| Agent Skills、AGENTS.md | 標準対応 | 標準では無い。サードパーティ拡張または自作が必要 |
| 中断からの再開 | 会話単位（セッションファイル）。ターン途中の中断は再開しない | ターン、ツール呼び出し単位で再開する |
| 長時間・定期実行 | 無い | スリープ、子タスク、タスクグラフで実現できる |

### 10.3. 推奨

現時点では採用せず保留とする。理由は次のとおりである。

- CLIを持たず、Open Terminalから直接起動できない。採用には独自ホストの開発が必要で、改修を最小にする方針と衝突する。
- APIが予告なく変わると明記されており、更新のたびにホストの追従が必要になる。
- 本構成の依頼は、通常モデルでもPiでも1〜5分で完走する。この規模では耐久実行の利点が出にくい。
- 指示とSkillはホームのファイルとして配布しており、ハーネスに依存しない。後から移っても失うものが少ない。

## References

- [Pi Durable (npm)](https://www.npmjs.com/package/@earendil-works/pi-durable)
- [Pi coding agent (npm)](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
- [Open Terminal skills and AGENTS.md (main.py)](https://github.com/open-webui/open-terminal/blob/v0.17.22/open_terminal/main.py)
- [Open Terminal user isolation](https://github.com/open-webui/open-terminal/blob/v0.17.22/open_terminal/utils/user_isolation.py)
