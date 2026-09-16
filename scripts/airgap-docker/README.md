# Air-gap資材の検証

Ubuntu 22.04 imageでは`out/deb/ubuntu-22.04`のDEBと`out/pypi`のPyPI packageを、Node.js 20 Alpine imageでは`out/npm`のnpm packageをnetworkなしで導入する。

## 検証手順

```powershell
# base imageを事前に取得する。
wsl -d Ubuntu -- docker pull ubuntu:22.04
wsl -d Ubuntu -- docker pull node:20-alpine

# repository rootからCompose定義を検証する。
wsl -d Ubuntu -- docker compose --profile verify -f scripts/airgap-docker/compose.yaml config --quiet

# build中のnetworkを無効にしてDEB、PyPI、npm資材を検証する。
wsl -d Ubuntu -- docker compose --profile verify -f scripts/airgap-docker/compose.yaml build --no-cache
```

期待結果:

- `ubuntu22.04` imageでDEBの依存解決と`chardet`のimportが成功する。
- `node20-alpine` imageで`tailwindcss`のoffline installと`require`が成功する。

失敗条件:

- local資材だけでは依存を解決できず、いずれかのbuild stepが非`0`で終了する。
- build中に外部network accessが必要になる。
