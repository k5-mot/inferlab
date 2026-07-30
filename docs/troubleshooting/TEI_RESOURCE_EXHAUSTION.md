# TEI起動時のホストresource枯渇

## 概要

Text Embeddings Inference（TEI）のembedding serviceとreranking serviceを起動した際、SSH接続が不安定になった。network障害と同じ時間帯にhostのmemory pressure、swap使用量増加、OOM kill、container再起動が確認された。

## 影響

- SSHとCodexの応答が遅延または切断する。
- host上の複数processがOOM killerの対象になる可能性がある。
- TEI containerが再起動を繰り返し、resource pressureが継続する。
- network処理とDocker内蔵resolverの応答も遅延し、L2障害に似た見え方になる。

## 確認された事実

- TEI 2サービスの起動時に物理memoryとswapが逼迫した。
- kernel logにOOM killが複数記録された。
- 無制限の`restart: unless-stopped`により、失敗したTEIが再起動して負荷を再発させる構成だった。
- 高いclient batch、同時request、tokenization worker設定が同時に有効だった。

## 原因

TEI 2サービスの合計resource要求がhostの余力を超え、swapとOOMを発生させた。restart loopが同じmodel loadとmemory確保を繰り返し、SSHを含むhost全体の応答性を低下させた。

この原因はgateway neighbourが`FAILED`になるARP/L2障害とは別に扱う。両者が同時に発生する可能性があるため、再発時はnetwork状態とresource状態を同じ時刻で採取する。

## 実施した対応

TEIのembedding serviceとreranking serviceへ、次の制限を適用した。

- restart policyを`on-failure:3`へ変更した。
- `--max-batch-tokens`を`1024`に制限した。
- `--max-client-batch-size`を`2`に制限した。
- `--max-concurrent-requests`を`2`に制限した。
- `--tokenization-workers`を`1`に制限した。
- `--auto-truncate true`を有効化した。
- 各serviceへmemory `6g`、memoryとswapの合計`7g`、CPU `4.0`の上限を設定した。
- 再発時はOOM、swap、PSI、Docker resource、restart count、TEI logを同じ時刻で採取する運用にした。

## 復旧確認

- Compose設定が正常に解決できることを確認した。
- TEI 2サービスが`healthy`になることを確認した。
- 再起動回数、`OOMKilled`、memory pressureを次回負荷試験の継続監視対象とした。

## 残存risk

2つのserviceが同時に上限までmemoryを使用すると、host全体の余力は依然として小さくなる。OpenWebUIやDoclingなどの重量serviceと同時起動する場合は、段階起動と`docker stats`による確認が必要である。

## References

- [TEIのCompose設定](../../10-inference/docker-compose.yml)
