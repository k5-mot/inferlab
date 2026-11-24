# Container patch監査

## 調査範囲

2026年11月25日時点で、Composeからcustom buildまたはruntime patchを適用しているcontainerを抽出し、利用中versionの公式sourceと現行upstreamを照合した。

| 対象 | 自前変更 | 判定 |
| --- | --- | --- |
| OIKB 0.6.0 | Open WebUI timeout、登録完了待ち、source逐次scheduler | 継続が必要 |
| Open WebUI 0.13.4 | Docling向けPDF分割とpage metadata補正 | 継続が必要 |
| Hermes-Agent v2026.9.24 | 補助LLM呼び出しへのLangfuse相関header注入 | 継続が必要 |
| mcpo | 公式`main`を内容変更なしで再build | 不要 |
| Cloudflare OS | Keycloak gatekeeperとLiteLLM model自動注入 | 継続が必要 |

## OIKB 0.6.0

OIKBの現行`main`はversion 0.6.0であり、利用中imageと同じversionである。upgradeによってpatchが取り込まれた状態ではない。

### Open WebUI timeout

公式`_make_client()`はURLとtokenだけを`OikbClient`へ渡し、client既定値の120秒を変更する環境変数を持たない。大容量document処理に`OIKB_OPENWEBUI_TIMEOUT=21600`を反映する自前patchは引き続き必要である。

### 登録完了待ち

公式`upload_file()`は`POST /files/`のresponseを返した時点で終了する。`process_in_background=false`、file処理status、Knowledge Baseへのlink完了、失敗時cleanupとretryは実装されていない。次のfileへ進む前にOpen WebUI側の登録完了を保証する自前patchは引き続き必要である。

### Source逐次scheduler

公式daemonはsourceごとに`asyncio.create_task()`を作成するため、複数sourceを同時にscheduleする。設定順で1 sourceずつ実行し、先行source失敗時に後続sourceを開始しない運用要件はupstreamに存在しない。scheduler、global lock、dry-run detail、処理中file表示を追加する自前patchは引き続き必要である。

## Open WebUI 0.13.4

公式0.13.4の`DoclingLoader`はPDF全体を1回の`POST /v1/convert/file`で送信し、`DOCLING_PDF_BATCH_PAGES`、`PdfReader`、PDF物理分割を実装していない。大容量PDFを一定page数に分割し、分割後のpage metadataを原本pageへ戻すruntime patchは引き続き必要である。

公式loaderはDoclingのMarkdownとJSONからpage番号を復元する機能を持つが、送信前のfile分割とは別機能である。したがってpage metadata対応が追加されたことだけを理由に自前分割patchを削除してはならない（MUST NOT）。

## Hermes-Agent v2026.9.24

`litellm-langfuse-headers` pluginは通常turnの`llm_request` middlewareに加え、`agent.relay_llm`の実行関数をruntimeでwrapしている。公式v2026.9.24では通常turnが`apply_llm_request_middleware()`を通る一方、要約や圧縮などの補助LLM呼び出しは`relay_llm.execute_current()`、`execute_current_async()`、`stream_current()`を直接呼び、`llm_request` middlewareを通らない。

現行upstreamの`agent/auxiliary_client.py`にも同じ直接呼び出しが残っている。補助LLM呼び出しを通常turnと同じLangfuse traceへ関連付ける要件を維持する限り、Relay入口で相関headerを注入するruntime patchは引き続き必要である。

## mcpo

`20-owui/mcpo/Dockerfile`は`ghcr.io/open-webui/mcpo:main`を`FROM`するだけで、file追加、package追加、source変更を行わない。公式documentationも同じpublished imageをComposeから直接使用する手順を示している。

custom buildと`main-patch2`というlocal tagに機能差はないため、`build`とDockerfileを削除し、公式imageを直接参照するべきである（SHOULD）。再現性を上げる場合はrelease tagまたはdigestへ固定する。

## Cloudflare OS

自前patchは、Keycloak用gatekeeper package、OAuth callback、local development binding、LiteLLM modelの環境変数注入を追加する。公式upstreamはGoogle、GitHub、Cloudflareなどのauth gatekeeperを提供するが、Keycloak gatekeeperを同梱していない。また、任意のOpenAI互換providerをUIから登録できる一方、`LITELLM_MODEL`などの環境変数から共通modelを自動登録する実装はない。

Keycloak loginとCompose管理のLiteLLM routeを要件として維持する限り、自前patchは必要である。patchはcommit `df04e239ed85376643c586a7329d3b8604df489e`へ固定されているため、Cloudflare OSのrefを更新する前に新しいupstreamへrebaseし、testを通さなければならない（MUST）。

## 結論

- 削除対象はmcpoの空custom buildだけである。
- OIKBの3patchは現行upstream 0.6.0にも同等機能がないため維持する。
- Open WebUIのDocling PDF分割patchは0.13.4に同等機能がないため維持する。
- Hermes-AgentのRelay runtime patchは補助LLM呼び出しが公式middlewareを経由しないため維持する。
- Cloudflare OS patchはupstream未提供のKeycloak/LiteLLM統合そのものであるため維持する。
- OIKBのlogや文書に残る`OIKB2`表記は製品名ではなく自前patch由来の文字列であり、`OIKB`へ統一できる。

## References

- [OIKB pyproject.toml](https://github.com/open-webui/oikb/blob/main/pyproject.toml)
- [OIKB CLI source](https://github.com/open-webui/oikb/blob/main/src/oikb/cli.py)
- [OIKB client source](https://github.com/open-webui/oikb/blob/main/src/oikb/client.py)
- [OIKB daemon source](https://github.com/open-webui/oikb/blob/main/src/oikb/daemon.py)
- [OIKB sync source](https://github.com/open-webui/oikb/blob/main/src/oikb/sync.py)
- [Open WebUI Docling documentation](https://github.com/open-webui/docs/blob/main/docs/features/chat-conversations/rag/document-extraction/docling.md)
- [Open WebUI 0.13.4 source](https://github.com/open-webui/open-webui/tree/v0.13.4)
- [Hermes-Agent v2026.9.24 turn request source](https://github.com/NousResearch/hermes-agent/blob/v2026.9.24/agent/turn_api_request.py)
- [Hermes-Agent v2026.9.24 auxiliary client source](https://github.com/NousResearch/hermes-agent/blob/v2026.9.24/agent/auxiliary_client.py)
- [Hermes-Agent current auxiliary client source](https://github.com/NousResearch/hermes-agent/blob/main/agent/auxiliary_client.py)
- [Hermes-Agent middleware documentation](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/middleware.md)
- [mcpo official repository](https://github.com/open-webui/mcpo)
- [Open WebUI MCP deployment documentation](https://github.com/open-webui/docs/blob/main/docs/features/extensibility/plugin/tools/openapi-servers/mcp.mdx)
- [Cloudflare OS OAuth sign-in](https://github.com/cloudflare/cloudflare-os/blob/main/docs/oauth-signin.md)
- [Cloudflare OS source](https://github.com/cloudflare/cloudflare-os)
