# OpenWebUIファイル取込時のDocling負荷

## 概要

OpenWebUIへfileをuploadし、Doclingによる文書変換と画像説明を実行した際、SSH接続が途切れる事象が発生した。画像説明機能は必要なため、機能無効化ではなく同時実行数と生成量を抑える方針を採用した。

## 影響

- 文書変換中にCPU、memory、disk I/Oが集中する。
- 画像説明APIへのrequestが重なると、LiteLLM、model backend、Doclingの負荷が連鎖する。
- host resourceに余力がない場合、SSHと他のDocker serviceが不安定になる。

## 確認された事実

- OpenWebUIのfile upload直後にSSH切断が再現した。
- Doclingの画像説明はLiteLLM経由でmodel APIを呼び出す構成だった。
- 画像説明を無効化する案は要件を満たさないため採用しなかった。
- host resource枯渇の有無を同時刻のlogとmetricsで確認する必要があった。

## 実施した対応

- Doclingの`document_timeout`を`180`秒に設定した。
- 画像説明APIのtimeoutを`120`秒に設定した。
- 画像説明APIの`concurrency`を`1`に制限した。
- 画像説明の`max_new_tokens`を`256`に制限した。
- temperatureを`0.0`へ固定し、再生成による変動を抑えた。
- full設定とslim設定を分け、画像説明が不要な切り分け時に設定を変更できる構成へ整理した。
- OpenWebUI起動時にDocling parameterをmultipart送信用へ正規化するscriptを維持した。

## 現在の運用

通常運用ではComposeで`docling_params_slim.json`をmountし、画像説明を無効にした設定を使用する。画像説明を検証する場合だけ`docling_params_full.json`へ切り替える。再発時は機能を直ちに削除せず、次の順序で切り分ける。

1. hostのOOM、swap、PSI、Docker resourceを採取する。
2. Docling、OpenWebUI、LiteLLM、model backendのlog時刻を比較する。
3. resource pressureが高い場合は、Doclingの同時処理とmodel backend負荷を優先して確認する。
4. 画像説明が必要な検証期間だけfull設定を使用し、通常構成へ戻す。

## 残存risk

画像数が多い文書では、`concurrency: 1`でも処理時間が長くなり、model backendのmemory使用量が継続する。TEI、Ollama、Doclingを同時に高負荷にする操作はhost resourceの余力を確認してから実施する。

## References

- [OpenWebUIとDoclingのCompose設定](../../20-owui/docker-compose.yml)
- [Docling full parameter](../../20-owui/open-webui/docling_params_full.json)
- [Docling slim parameter](../../20-owui/open-webui/docling_params_slim.json)
- [TEI起動時のhost resource枯渇](TEI_RESOURCE_EXHAUSTION.md)
