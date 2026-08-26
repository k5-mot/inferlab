# パッケージ資材ダウンロード仕様

## 目的

`script/Download-Pip-Packages.ps1`と`script/Download-Npm-Packages.ps1`は、対象projectの依存定義を正本として、airgap環境のregistryへ投入できるpackage資材を事前取得する。

## PyPI資材

`Download-Pip-Packages.ps1`は`requirements.txt`を正本にしなければならない（MUST）。

`Download-Pip-Packages.ps1`が公開する引数は`-OutputDir`、`-ProjectDirectory`、`-Help`だけでなければならない（MUST）。`-ProjectDirectory`を省略した場合、scriptはカレントディレクトリを対象project directoryとして扱わなければならない（MUST）。

対象project directoryに`pyproject.toml`が存在する場合、scriptはdownload前に`uv export`で`requirements.txt`を生成しなければならない（MUST）。生成するrequirementsはproject package自身を含めず、hashとindex URLを含めない。`uv.lock`が存在する場合はlocked解決を使用しなければならない（MUST）。

対象project directoryに`pyproject.toml`が存在しない場合、scriptは同じdirectoryの既存`requirements.txt`を使用しなければならない（MUST）。

scriptは`requirements.txt`の各requirementをmirror対象の完全リストとして扱い、各行のdownload時にtransitive dependencyを再解決してはならない（MUST NOT）。uv projectでは`uv export`がtransitive dependencyを含むrequirementsを生成する。

scriptは既定で次のPython versionを対象にしなければならない（MUST）。

- `3.10`
- `3.11`
- `3.12`
- `3.13`
- `3.14`

scriptは既定で次のplatform groupを対象にしなければならない（MUST）。

- Any
- Linux x86_64
- Windows x86/x64

Any向けには`any`を指定する。Windows向けには`win32`と`win_amd64`を指定する。Linux x86_64向けには`manylinux_2_17_x86_64`、`manylinux_2_28_x86_64`、`manylinux2014_x86_64`、`manylinux1_x86_64`を指定する。

scriptはbinary wheelを優先して取得しなければならない（MUST）。同じrequirementとPython versionについてwheel取得結果がskip許容条件を満たさない場合、scriptはsource archiveをfallback取得してよい（MAY）。

対象packageが特定platform向けwheelを提供していない場合、scriptはそのplatformをskipしてよい（MAY）。ただし、skipを許容できるのは、同じrequirementとPython versionについて`any` packageを取得できた場合、またはWindows groupとLinux groupでそれぞれ1つ以上のpackageを取得できた場合に限る（MUST）。

対象requirementがPyPI metadata上で対象Python versionをsupportしない場合、scriptはそのrequirementとPython versionの組み合わせをskipしてよい（MAY）。

PyTorch CPU wheel用の追加indexは、script内部で`torch`、`torchvision`、`torchaudio`にだけ適用しなければならない（MUST）。利用者へ追加index引数を公開してはならない（MUST NOT）。

成果物は`.whl`、fallback時の`.tar.gz`または`.zip`として`-OutputDir`へ保存する。

## npm資材

`Download-Npm-Packages.ps1`は`package.json`を正本にしなければならない（MUST）。

`Download-Npm-Packages.ps1`が公開する引数は`-OutputDir`、`-ProjectDirectory`、`-Help`だけでなければならない（MUST）。`-ProjectDirectory`を省略した場合、scriptはカレントディレクトリを対象project directoryとして扱わなければならない（MUST）。

scriptは対象project directory直下の`package.json`だけを読み取らなければならない（MUST）。対象project directoryに`node_modules`、`package-lock.json`、その他の作業fileを作成してはならない（MUST NOT）。

scriptは`dependencies`、`devDependencies`、`optionalDependencies`からdownload対象のroot packageを取得しなければならない（MUST）。`workspace:`、`file:`、`link:`のlocal dependencyはregistry投入対象ではないため除外しなければならない（MUST）。

scriptは`npm install --package-lock-only`で対象platformごとの依存解決を行い、解決済みpackageを`npm pack`で`.tgz`として取得しなければならない（MUST）。`package-lock.json`に記録されたpackageに`os`または`cpu`条件がある場合、target platformに一致しないpackageは取得対象から除外しなければならない（MUST）。

scriptは既定で次のplatformを対象にしなければならない（MUST）。

- Linux x64
- Windows x64

成果物の`.tgz`は標準npm registry tarballとして扱う。Verdaccioへpublishした後、npm、pnpm、yarnはいずれも同じregistryから取得できなければならない（MUST）。

download成果物はpackage manager固有storeではなく、Verdaccio投入用の標準`.tgz`でなければならない（MUST）。

## Registry投入

PyPI資材はairgap環境の`/srv/12-registry/pypi`へ配置する。pypiserverはこのdirectoryをread-only mountし、配置済みpackageを配信する。

npm資材はairgap環境の`/srv/12-registry/npm-packages`へ配置する。npm importerはこのdirectoryの`.tgz`をVerdaccioへ冪等にpublishする。

## 失敗条件

scriptは次の場合に非ゼロ終了しなければならない（MUST）。

- 必要なcommandが見つからない。
- requirements.txtまたはpackage.jsonが見つからない。
- uv projectでrequirements.txtを生成できない。
- target versionまたはtarget platform向けpackageの取得結果がskip許容条件を満たさない。
- 成果物directoryにpackage archiveが作成されない。

## References

- [../12-registry/MANUAL.md](../12-registry/MANUAL.md)
