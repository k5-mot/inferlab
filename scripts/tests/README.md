# Download scriptのテスト

`Test-*.ps1`は、対応する`Download-*.ps1`のPowerShell構文と共通要件を検証する。

検証項目:

- 公開引数が`OutputDir`、`ProjectDir`、`Help`の許可された組み合わせだけである。
- ダウンロード元の`$Registries`配列と対象packageの`$Packages`配列が定義されている。
- 出力先directoryが`scripts/README.md`の構成と一致する。
- すべてのfunctionに目的、parameter、return valueを説明するdocumentation commentがある。
- PyPI向けscriptにPython 3.12から3.15と8 platformが定義されている。
- `requirements.txt`と`package.json`のfixtureが有効である。

## 実行手順

```powershell
# network downloadを行わず、すべてのdownload scriptを静的検証する。
Get-ChildItem ./scripts/tests/Test-*.ps1 | ForEach-Object {
    $Arguments = if ($_.Name -like "*-from-Project.ps1") { @("-Static") } else { @() }
    pwsh -NoProfile -File $_.FullName @Arguments
}
```

期待結果:

- すべてのtestが終了code `0`で完了する。

失敗条件:

- PowerShell構文errorまたは要件違反により、いずれかのtestが非`0`で終了する。

## from-Project版のdownload検証

`requirements.txt`と`package.json`には、実際にdownloadする検証用packageを定義する。

```powershell
# requirements.txtを入力としてPython packageを取得する。
pwsh -NoProfile -File ./scripts/tests/Test-PipPkgs-from-Project.ps1

# package.jsonを入力としてnpm packageを取得する。
pwsh -NoProfile -File ./scripts/tests/Test-NpmPkgs-from-Project.ps1
```

期待結果:

- `scripts/tests/.tmp/pypi-from-projects/pypi/`にPython package archiveが作成される。
- `scripts/tests/.tmp/npm-from-projects/npm/`にnpm package archiveが作成される。
- fixture directoryに作業fileが残らない。

失敗条件:

- fixtureに不正なpackage定義がある。
- 対象versionまたはplatform向けpackageを取得できない。
- fixture directoryに`node_modules`、`package-lock.json`、生成した`requirements.txt`が残る。
