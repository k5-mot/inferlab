# boot-md

Hermes gateway の `gateway:startup` event hook で、InferLab 用の初期化スクリプトを実行します。

実処理は `bootstrap.sh` に置き、`handler.py` は gateway 起動イベントの受け口とログ出力だけを担当します。

## References

- [Tutorial: BOOT.md — Run a Startup Checklist on Every Gateway Boot](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks#tutorial-bootmd--run-a-startup-checklist-on-every-gateway-boot)
