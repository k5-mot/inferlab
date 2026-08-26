# パッケージ資材ダウンロード手順

この手順は、対象projectのPython packageとnpm packageを事前downloadし、airgap環境のpypiserverとVerdaccioへ投入するための手順である。

## 前提

- 資材取得端末でPowerShell、Python 3、pip、Node.js、npmを実行できる。
- uv projectからrequirements.txtを生成する場合は、資材取得端末でuvを実行できる。
- npm、pnpm、yarn projectはいずれもpackage.jsonを持つ。
- airgap環境では[../12-registry/MANUAL.md](../12-registry/MANUAL.md)に従ってregistry serviceを起動できる。

置換する値:

- `<PROJECT_DIR>`: package定義fileがあるproject directory。
- `<ASSETS_DIR>`: 資材取得端末でpackage archiveを保存するdirectory。
- `<REGISTRY_USER>`: Registry serverへfile転送できるuser。
- `<REGISTRY_HOST>`: Registry serverのhost名またはIP address。

download scriptはrepository rootから対象project directoryを指定して実行できる。scriptを対象project directoryへコピーして実行する場合は、`-ProjectDirectory`を省略できる。

## 1. PyPI資材を取得する

uv projectでは、`pyproject.toml`と`uv.lock`があるdirectoryで実行する。scriptは先に`requirements.txt`を生成し、そのrequirementsからPython 3.10から3.14のany、Windows、Linux向けwheelを取得する。

```powershell
# script実行時だけPowerShell scriptの実行を許可する。
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# uv projectからrequirements.txtを生成し、pypiserver投入用wheelhouseを作成する。
.\script\Download-Pip-Packages.ps1 -ProjectDirectory <PROJECT_DIR> -OutputDir <ASSETS_DIR>\12-registry\pypi
```

`pyproject.toml`が無いprojectでは、同じdirectoryにある既存の`requirements.txt`を使用する。PyTorch CPU wheel用の追加indexはscript内部で`torch`、`torchvision`、`torchaudio`だけに適用される。

```powershell
# 既存requirements.txtだけを正本にしてwheelhouseを作成する。
.\script\Download-Pip-Packages.ps1 -ProjectDirectory <PROJECT_DIR> -OutputDir <ASSETS_DIR>\12-registry\pypi
```

期待結果:

- `<PROJECT_DIR>\requirements.txt`が存在する。
- `<ASSETS_DIR>\12-registry\pypi`に`.whl` fileが作成される。
- packageが特定platform向けwheelを提供しない場合、そのplatformはskipされる。
- 同じrequirementとPython versionについて`any`、またはWindowsとLinux双方のwheelが取得できる。

失敗基準:

- `uv export`または`pip download`が非ゼロ終了する。
- 同じrequirementとPython versionについて`any`が無く、WindowsまたはLinuxのどちらか一方も取得できない。
- `<ASSETS_DIR>\12-registry\pypi`にpackage archiveが作成されない。

## 2. npm資材を取得する

対象projectのpackage.jsonがあるdirectoryを指定して実行する。scriptはpackage.jsonからroot packageを取得し、Windows x64とLinux x64向けに一時directoryで依存解決したうえで、Verdaccio投入用`.tgz`を作成する。対象project directoryには`node_modules`、`package-lock.json`、その他の作業fileを作成しない。

```powershell
# package.jsonからVerdaccio投入用npm tarballを作成する。
.\script\Download-Npm-Packages.ps1 -ProjectDirectory <PROJECT_DIR> -OutputDir <ASSETS_DIR>\12-registry\npm-packages
```

期待結果:

- `<ASSETS_DIR>\12-registry\npm-packages`に`.tgz` fileが作成される。
- platform固有optional dependencyはLinux用とWindows用の両方が含まれる。

失敗基準:

- `npm install --package-lock-only`または`npm pack`が非ゼロ終了する。
- `<ASSETS_DIR>\12-registry\npm-packages`に`.tgz` fileが作成されない。

## 3. airgap環境へ転送する

```powershell
# 取得済みpackage資材をRegistry serverへ転送する。
scp -r <ASSETS_DIR>\12-registry <REGISTRY_USER>@<REGISTRY_HOST>:/srv/
```

期待結果:

- Registry server上に`/srv/12-registry/pypi`がある。
- Registry server上に`/srv/12-registry/npm-packages`がある。

失敗基準:

- `scp`が非ゼロ終了する。
- 転送先でpackage archiveが欠ける。

## 4. registry serviceで配信する

Registry server上でregistry profileを起動する。pypiserverは`/srv/12-registry/pypi`をread-only mountして配信する。npm importerは`/srv/12-registry/npm-packages/*.tgz`をVerdaccioへpublishする。

```bash
# repository rootへ移動する。
cd /path/to/repository

# pypiserver、Verdaccio、npm importerを含むregistry serviceを起動する。
sudo docker compose --env-file .env --profile registry up -d pypiserver verdaccio npm-importer

# registry serviceの状態を確認する。
sudo docker compose --env-file .env --profile registry ps pypiserver verdaccio npm-importer
```

期待結果:

- `pypiserver`と`verdaccio`がrunningまたはhealthyになる。
- `npm-importer` logにpublishまたはskipが表示される。

失敗基準:

- serviceが起動しない。
- `npm-importer` logにpublish失敗が出る。

## 5. 利用者端末から確認する

```bash
# pypiserverからPython packageを取得できることを確認する。
python -m pip install --index-url http://<REGISTRY_HOST>:31200/simple/ --trusted-host <REGISTRY_HOST> -r <PROJECT_DIR>/requirements.txt

# Verdaccioをnpm registryとして指定する。
npm config set registry http://<REGISTRY_HOST>:31201/

# Verdaccioからnpm packageを取得できることを確認する。
npm install
```

pnpmまたはyarnを使うprojectでは、registry URLを各package managerの設定へ指定してからinstallする。

期待結果:

- pipまたはuvがpypiserverからPython packageを取得できる。
- npm、pnpm、yarnがVerdaccioからnpm packageを取得できる。

失敗基準:

- package install時にinternet上のpublic registryへ接続しようとする。
- package不足でinstallが失敗する。

## References

- [../12-registry/MANUAL.md](../12-registry/MANUAL.md)
- [SPEC.md](SPEC.md)
