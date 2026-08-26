# パッケージダウンロード検証fixture

このdirectoryには、`k5-mot/private-chat`を元にした最小の検証fixtureを置く。

## PyPI fixture

`pip/requirements.txt`は、private-chat API側の`requirements.airgap.txt`を元にし、検証用に`pypandoc`と`pypdf`を加えたpinned requirementsである。`python-dotenv`と`python-docx`は元のrequirementsに含まれる。

```powershell
# repository rootから、fixtureを対象project directoryとして指定してwheelhouseを作成する。
.\script\Download-Pip-Packages.ps1 -ProjectDirectory .\script\tests\pip -OutputDir .\tmp\pypi-wheelhouse
```

期待結果:

- `tmp\pypi-wheelhouse`に`.whl` fileが作成される。
- wheelを提供しないplatformがあっても、scriptのskip許容条件を満たす場合は処理が継続する。

失敗基準:

- `pip download`が非ゼロ終了する。
- skip許容条件を満たさないpackageがある。
- `tmp\pypi-wheelhouse`に`.whl` fileが作成されない。

## npm fixture

`npm/package.json`は、private-chat app側の依存を元にし、検証用に`cowsay`と`figlet`を加えたmanifestである。

```powershell
# repository rootから、fixtureを対象project directoryとして指定してnpm tarballを作成する。
.\script\Download-Npm-Packages.ps1 -ProjectDirectory .\script\tests\npm -OutputDir .\tmp\npm-packages
```

期待結果:

- `tmp\npm-packages`に`.tgz` fileが作成される。
- `script\tests\npm`に`node_modules`や`package-lock.json`が作成されない。

失敗基準:

- `npm install --package-lock-only`または`npm pack`が非ゼロ終了する。
- `tmp\npm-packages`に`.tgz` fileが作成されない。
- `script\tests\npm`に作業fileが残る。

## References

- [k5-mot/private-chat](https://github.com/k5-mot/private-chat)
