# Air-gap project検証

`backend`はuv、Python、FastAPIを使用するUbuntu 22.04 project、`frontend`はTypeScript、Vite+、React、shadcn/ui、Tailwind CSSを使用するNode.js 20 Alpine projectである。directory構成はPrivate Chatの`api`と`app`を参考にしている。

資材は次のdirectoryへ保存する。

- `backend/deb/ubuntu-22.04`: Ubuntu 22.04向けDEB package
- `backend/pypi`: backendのPython wheel
- `frontend/npm`: frontendのnpm archive

## 資材取得手順

repository rootで次のcommandを実行する。

```powershell
# backendとfrontendのair-gap資材を各directoryへ取得する。
powershell -NoProfile -NonInteractive -ExecutionPolicy "Bypass" -File scripts/airgap-docker/Download-Assets.ps1
```

期待結果:

- 各directoryへ`.deb`、`.whl`、`.tgz`が作成される。
- backendの依存は`pyproject.toml`と`uv.lock`、frontendの依存は`package.json`と`package-lock.json`から解決される。

失敗条件:

- いずれかのdirectoryに対象archiveが作成されない。
- lockfileとproject定義が一致しない。

## Offline build検証手順

```powershell
# 検証に必要なbase imageを事前に取得する。
wsl -d Ubuntu -- docker pull ubuntu:22.04

# frontend検証用のbase imageを事前に取得する。
wsl -d Ubuntu -- docker pull node:20-alpine

# repository rootからCompose定義を検証する。
wsl -d Ubuntu -- docker compose --profile verify -f scripts/airgap-docker/docker-compose.yaml config --quiet

# build networkを無効化してbackendとfrontendをbuildする。
wsl -d Ubuntu -- docker compose --profile verify -f scripts/airgap-docker/docker-compose.yaml build --no-cache
```

期待結果:

- backend imageでlocal DEBとwheelだけを使用した`uv export`、`uv pip sync`、FastAPI importが成功する。
- frontend imageでlocal npm archiveだけを使用した`npm ci`、`vp check`、`vp build`が成功する。

失敗条件:

- local資材だけでは依存を解決できない。
- build中に外部network accessが必要になる。
- FastAPI import、Vite+ check、React production buildのいずれかが失敗する。

backendはflatなDEB集合をfile名順に設定しないよう、先に`dpkg --unpack`ですべて展開する。この時点ではPre-Dependsにより一部が保留されるため、続く`apt-get --fix-broken install`へ同じlocal `.deb`集合を明示して依存順序を解決し、`dpkg --configure -a`を実行する。local集合を明示しない`--fix-broken`は、目的のpackageを削除して整合性を回復する場合があるため使用しない。最後に`dpkg --audit`、Python、pipを確認し、apt cacheと検証資材を削除する。

`uv sync --frozen`はlockfileに記録されたregistry URLを優先し、`--find-links`のlocal wheelが存在してもoffline cacheを要求する既知の挙動がある。そのため、`uv export --frozen`でlockfileを固定requirementsへ変換し、`uv pip sync --no-index --offline --find-links`でlocal wheelだけを同期する。

## References

- [uv: Locking and syncing](https://docs.astral.sh/uv/concepts/projects/sync/)
- [uv: Offline sync with `--frozen` and `--find-links` issue](https://github.com/astral-sh/uv/issues/15519)
- [Vite+: Build](https://viteplus.dev/guide/build)
- [Private Chat](https://github.com/k5-mot/private-chat)
- [GitHub Node.gitignore](https://github.com/github/gitignore/blob/main/Node.gitignore)
- [GitHub Python.gitignore](https://github.com/github/gitignore/blob/main/Python.gitignore)
