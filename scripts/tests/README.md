# Download scriptのテスト

`Test-*.ps1`は、対応する`Download-*.ps1`のPowerShell構文と共通要件を検証する。

検証項目:

- 公開引数が`OutputDir`、`ProjectDir`、`Help`の許可された組み合わせだけである。
- ダウンロード元の`$Registries`配列と対象packageの`$Packages`配列が定義されている。
- 出力先directoryが`scripts/README.md`の構成と一致する。
- すべてのfunctionに目的、parameter、return valueを説明するdocumentation commentがある。
- PyPI向けscriptにPython 3.12から3.15と8 platformが定義されている。

## 実行手順

```powershell
# すべてのdownload script testを実行する。
Get-ChildItem ./scripts/tests/Test-*.ps1 | ForEach-Object { pwsh -NoProfile -File $_.FullName }
```

期待結果:

- すべてのtestが終了code `0`で完了する。

失敗条件:

- PowerShell構文errorまたは要件違反により、いずれかのtestが非`0`で終了する。
