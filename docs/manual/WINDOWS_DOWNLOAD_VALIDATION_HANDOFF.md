# Windowsダウンロード検証引継ぎ

## 目的

Windows側のCodexは、PowerShellダウンロードスクリプトのテスト用環境変数名とRPMテスト対象の変更を検証する。

対象commit:

- `75e9799`: `INFERLAB_DOWNLOAD_TEST`を`DOWNLOAD_TEST`へ変更し、テスト用一時directory名から`inferlab`を除去した。
- `5425ca7`: RPMテスト対象を`docker-scan-plugin`から`podman`へ変更し、Docker repositoryを削除した。

## 前提

- Windows PowerShell 5.1とPowerShell 7を利用できる。
- GitとInternet接続を利用できる。
- repository rootをcurrent directoryとして実行する。
- smoke testに必要な外部commandがない場合、skip理由を結果へ記録する。

## 1. mainを更新する手順

```powershell
# main branchへ移動する。
git switch main

# origin/mainをfast-forwardで取得する。
git pull --ff-only origin main

# 検証対象commitがmainに含まれることを確認する。
git merge-base --is-ancestor 75e9799 HEAD
git merge-base --is-ancestor 5425ca7 HEAD
```

期待結果:

- `git pull --ff-only`がmerge commitを作成せず終了code `0`で完了する。
- 2つの`git merge-base`が終了code `0`で完了する。

失敗条件:

- working treeの変更またはbranchの分岐によりfast-forwardできない。
- いずれかの対象commitが`HEAD`に含まれない。

## 2. 固有名を除去したことの検証手順

```powershell
# 旧テスト用環境変数がPowerShell scriptに残っていないことを確認する。
git grep -n "INFERLAB_DOWNLOAD_TEST" -- "*.ps1"
if ($LASTEXITCODE -eq 0) { throw "INFERLAB_DOWNLOAD_TESTが残っています。" }
if ($LASTEXITCODE -ne 1) { throw "git grepの実行に失敗しました。" }

# 旧テスト用一時directory名がPowerShell scriptに残っていないことを確認する。
git grep -n -i "inferlab-download" -- "*.ps1"
if ($LASTEXITCODE -eq 0) { throw "inferlab-downloadが残っています。" }
if ($LASTEXITCODE -ne 1) { throw "git grepの実行に失敗しました。" }

# 新しいテスト用環境変数の使用箇所を一覧表示する。
git grep -n "DOWNLOAD_TEST" -- "*.ps1"
```

期待結果:

- 旧名称を探す2つの`git grep`が何も表示せず終了code `1`を返す。
- 新名称の一覧にdownload scriptと`Invoke-DownloadTest.ps1`が含まれる。

失敗条件:

- `INFERLAB_DOWNLOAD_TEST`または`inferlab-download`が1件以上見つかる。
- download scriptとtest helperで異なる環境変数名を使用している。

## 3. PowerShell静的検証手順

```powershell
# すべてのdownload script verificationをPowerShell 7で実行する。
Get-ChildItem ./scripts/tests/Verify-*.ps1 | ForEach-Object {
    # 個々のverificationを独立したprocessで実行する。
    pwsh -NoProfile -File $_.FullName
    # 非0終了を検出した時点で検証を失敗させる。
    if ($LASTEXITCODE -ne 0) { throw "verification failed: $($_.Name)" }
}
```

期待結果:

- すべてのverificationが終了code `0`で完了する。

失敗条件:

- PowerShell構文error、公開引数違反、配列定義不足、またはdocumentation comment違反が発生する。

## 4. RPMのWindows実行検証手順

```powershell
# 検証成果物の保存先をrepository配下の限定directoryに固定する。
$ValidationRoot = Join-Path (Resolve-Path .) "scripts/tests/.tmp/windows-rpm-validation"

# 過去の検証成果物だけを削除する。
Remove-Item -LiteralPath $ValidationRoot -Recurse -Force -ErrorAction SilentlyContinue

# 軽量テスト分岐を有効化する。
$PreviousDownloadTest = $env:DOWNLOAD_TEST
$env:DOWNLOAD_TEST = "1"
try {
    # Windows PowerShell 5.1でPodman RPMを取得する。
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ./scripts/Download-RPM.ps1 -OutputDir $ValidationRoot
    # download scriptの非0終了を検出する。
    if ($LASTEXITCODE -ne 0) { throw "Download-RPM.ps1 failed: $LASTEXITCODE" }
}
finally {
    # 呼び出し前の環境変数値を復元する。
    $env:DOWNLOAD_TEST = $PreviousDownloadTest
}

# Podman本体のRPMが作成されたことを確認する。
$PodmanRpms = @(Get-ChildItem (Join-Path $ValidationRoot "rpm") -Filter "podman-*.rpm" -File)
if ($PodmanRpms.Count -eq 0) { throw "Podman RPMが作成されていません。" }

# Docker関連RPMが作成されていないことを確認する。
$DockerRpms = @(Get-ChildItem (Join-Path $ValidationRoot "rpm") -Filter "*docker*.rpm" -File)
if ($DockerRpms.Count -ne 0) { throw "Docker関連RPMが作成されています。" }

# 取得したRPM名を検証結果へ記録する。
Get-ChildItem (Join-Path $ValidationRoot "rpm") -Filter "*.rpm" -File | Select-Object -ExpandProperty Name

# 検証完了後に限定directoryを削除する。
Remove-Item -LiteralPath $ValidationRoot -Recurse -Force
```

期待結果:

- `Download RPM packages: podman`が表示される。
- `podman-*.rpm`が1件以上作成される。
- `*docker*.rpm`が作成されない。
- 検証後に`windows-rpm-validation` directoryが残らない。

失敗条件:

- Windows PowerShell 5.1で構文errorまたはdownload errorが発生する。
- Podman本体のRPMがない、またはDocker関連RPMが含まれる。
- cleanup後も検証成果物が残る。

既知の観測事項:

- Linux上の事前検証では、既存のRPM依存解決処理から`iptables`、`oci-runtime`、`glibc-langpack`が見つからないwarningが表示された。
- Windowsでも同じwarningが出た場合、出力全文と取得RPM一覧を報告し、Podmanのoffline installに必要なprovider packageが不足していないかを確認する。

## 5. 全smoke testの実行手順

```powershell
# 実行可能な全download smoke testをPowerShell 7で実行する。
Get-ChildItem ./scripts/tests/Test-*.ps1 | ForEach-Object {
    # 個々のsmoke testを独立したprocessで実行する。
    pwsh -NoProfile -File $_.FullName
    # 非0終了を検出した時点で検証を失敗させる。
    if ($LASTEXITCODE -ne 0) { throw "smoke test failed: $($_.Name)" }
}
```

期待結果:

- 実行可能なtestが終了code `0`で完了する。
- test helperが`DOWNLOAD_TEST`を設定し、各scriptが軽量な対象だけを取得する。

失敗条件:

- 旧環境変数名との不一致により通常の全package downloadが始まる。
- download失敗、成果物不足、またはchecksum不一致が発生する。

## 6. 検証結果の引継ぎ形式

Windows側Codexは、以下を返す。

- Windows version、PowerShell 5.1 version、PowerShell 7 version。
- 静的verificationとsmoke testの成功、失敗、skip件数。
- `Download-RPM.ps1`の終了codeと取得RPM一覧。
- RPM依存解決warningの有無と全文。
- 失敗した場合は再現command、最初のerror、関連file、修正候補。
