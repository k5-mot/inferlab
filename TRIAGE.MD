# ネットワーク切断再発の対策

## 前提

- Cloudflare Tunnel と Hermes-Agent は停止せず、外部からの操作経路として維持する。
- 2026-07-18 08:00-09:00 JST の再発時、`enp2s0` のリンクダウンや `bridge0` からの脱落は確認されていない。
- Docker ログでは、複数コンテナから外部 DNS への問い合わせが `i/o timeout` になっていた。
- timeout 先は `192.168.1.1` だけでなく、`1.1.1.1` と `8.8.8.8` も含まれていた。
- 以前追加した Cloudflare / Hermes-Agent 向け DNS 安定化設定は有効だが、対象外コンテナからの外部問い合わせが残っている。

## 優先度 高

- 外部通信する全コンテナへ DNS 安定化設定を展開する。
  - `dns: [1.1.1.1, 8.8.8.8]`
  - `dns_search: [.]`
  - `dns_opt: ["timeout:1", "attempts:2", "ndots:1"]`
- `.localdomain` 付きの不要な DNS 再試行をなくす。
  - `api.gradio.app.localdomain`
  - `raw.githubusercontent.com.localdomain`
  - `telemetry.qdrant.io.localdomain`
  - `ollama.com.localdomain`
- Qdrant telemetry を無効化する。
  - `telemetry.qdrant.io` への問い合わせを止め、通常運用時の外部 DNS 負荷を減らす。
- Ollama のモデル取得を通常起動経路から分離する。
  - `ollama-init` の `ollama pull` は外部 DNS と外部通信を発生させるため、手動実行または明示的な初期化 profile に切り出す。
- 一括起動を避け、段階起動にする。
  - `common`
  - `cloudflare`
  - `hermes-agent`
  - `storage`
  - `webui` / `inference` / `automation`
- Cloudflare と Hermes-Agent を先に起動し、操作経路が安定してから重いサービスを起動する。

## 優先度 中

- Docker daemon 側にも共通 DNS 設定を入れる。
  - Compose 側の設定漏れを daemon 側で補う。
  - `/etc/docker/daemon.json` の `dns` と `dns-search` を確認する。
- host 側にローカルキャッシュ DNS を置く。
  - `unbound` または `dnsmasq` を候補にする。
  - Docker コンテナからは host のキャッシュ DNS を参照させる。
- Docker ネットワークを用途別に分離する。
  - Cloudflare / Hermes-Agent 用の重要経路
  - WebUI / Dify / Ollama などの通常アプリ経路
  - telemetry や初期化処理が発生する経路
- 不要な外部通信を停止する。
  - telemetry
  - update check
  - 起動時の npm / pip install
  - 起動時のモデル pull
- DNS timeout が発生したコンテナを特定しやすくする。
  - コンテナ名と IP の対応を定期的に保存する。
  - `docker network inspect inferlab_internal-nw` の結果を障害時ログに含める。

## 優先度 低

- conntrack の利用量と上限を監視する。
  - `conntrack -C`
  - `conntrack -S`
  - `sysctl net.netfilter.nf_conntrack_max`
- ルータ側の NAT / DNS 負荷を確認する。
  - `192.168.1.1` だけでなく public DNS も timeout しているため、ホスト外の経路も確認対象にする。
- Cloudflare Tunnel の再接続失敗を監視する。
  - `region1.v2.argotunnel.com` の DNS timeout をアラート対象にする。
- SSH の代替入口を維持する。
  - LAN 直接 SSH
  - Cloudflare Tunnel 経由 SSH
  - ローカルコンソール

## 再発時に採取する情報

```bash
date
ip addr
ip link
ip route
bridge link
bridge vlan
docker ps
docker network inspect inferlab_internal-nw
journalctl -b --since "30 minutes ago" --no-pager
journalctl -b -u NetworkManager -u systemd-resolved -u docker --since "30 minutes ago" --no-pager
conntrack -C
conntrack -S
sysctl net.netfilter.nf_conntrack_max
```

## 実装順

1. Qdrant telemetry を無効化する。
2. `ollama-init` のモデル取得を通常起動から外す。
3. 外部通信する全サービスへ DNS 安定化設定を展開する。
4. Cloudflare / Hermes-Agent を先行起動する段階起動スクリプトを作る。
5. Docker daemon 側の DNS 設定を確認し、必要なら host 設定として追加する。
6. 再発時採取スクリプトを作成し、障害時の conntrack と Docker network 状態を保存する。
