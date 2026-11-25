# Open WebUI API index

Open WebUI v0.13.4のOpenAPI Schemaから生成した。手で編集しない。

| Skillまたは除外理由 | operation数 |
| --- | --- |
| 除外: UI用のchangelog。 | 1 |
| 除外: Pi自身をagent modelとして呼べるため、再帰防止で禁止する。 | 3 |
| 除外: UI用のserver設定。agentから使う必要がない。 | 1 |
| 除外: 推論はLiteLLMへ集約する。RAGはowui-knowledge経由で使う。 | 1 |
| 除外: event webhookの登録。外部へのdata送信先を変更できるため禁止する。 | 5 |
| 除外: Anthropic Messages互換のchat APIであり、再帰防止で禁止する。 | 2 |
| owui-models | 24 |
| 除外: 同上。 | 9 |
| 除外: server全体の利用統計 (experimental)。agentから使う必要がない。 | 1 |
| 除外: 管理機能。 | 20 |
| 除外: 外部app連携の管理。app interactionはchannel返信としてmodelを呼ぶため、再帰防止で禁止する。 | 8 |
| owui-audio | 6 |
| 除外: 認証情報の発行・変更を伴うため禁止する。 | 39 |
| 除外: agent modelを定期実行できるため、再帰防止で禁止する。 | 10 |
| owui-calendar | 14 |
| owui-channels | 33 |
| owui-chats | 56 |
| owui-comments | 11 |
| 除外: 管理機能（owui-admin、原則無効）。 | 64 |
| owui-evaluations | 15 |
| owui-files | 16 |
| owui-folders | 15 |
| 除外: server側code実行の登録を伴うため禁止する。 | 22 |
| owui-images | 7 |
| owui-knowledge | 39 |
| owui-memory | 12 |
| owui-notes | 13 |
| owui-notifications | 11 |
| owui-prompts | 15 |
| 除外: query、web以外はRAG設定の変更やresetを含む管理機能。 | 12 |
| owui-web-search | 2 |
| owui-search | 1 |
| owui-skills | 21 |
| 除外: chat taskの制御であり、agent loopから使う必要がない。 | 10 |
| 除外: Open Terminal経由でagent sessionを起動できるため、再帰防止で禁止する。 | 31 |
| owui-tools | 23 |
| 除外: server側code実行とDB downloadを含むため禁止する。 | 4 |
| 除外: 動画生成engineを構成していない。configは管理機能。 | 6 |
| 除外: server meta情報。agentから使う必要がない。 | 2 |
| 除外: UI用のcache file配信。fileはowui-filesで取得する。 | 1 |
| 除外: 死活確認。 | 3 |
| 除外: UI用のweb app manifest。 | 1 |
| 除外: 認証flow。 | 6 |
| 除外: 推論はLiteLLMへ集約する。 | 64 |
| 除外: UI用のbrowser検索定義。 | 1 |

## 未分類

Skillにも除外にも分類していないoperation。生成scriptは未分類があると終了code 1で終了する。

なし。
