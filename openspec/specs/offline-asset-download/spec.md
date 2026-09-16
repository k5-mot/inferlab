# 閉域資材事前取得 Specification

## Purpose

user profileが容量制限付きnetwork driveである環境でも、事前取得scriptが指定された`OutputDir`側の容量を使って閉域持ち込み資材を作成できることを定めます。

## Requirements

### Requirement: npmの作業領域はOutputDir側に限定する

`Download-NpmPkgs.ps1`と`Download-NpmPkgs-from-Project.ps1`は、npmの作業directoryとcacheを`OutputDir`配下に作成しなければならない（MUST）。`Download-NpmPkgs-from-Project.ps1`は、package-lock解析用parserも同じ作業directoryに作成しなければならない（MUST）。

#### Scenario: user profileのnpm cacheが使用できない

- **WHEN** 呼び出し元のnpm cacheが容量制限で使用できない状態でscriptを実行する
- **THEN** すべてのnpm commandは`OutputDir`配下のcacheを明示してpackage archiveを作成する
- **THEN** scriptは処理終了時に一時作業directoryとparserを削除する

### Requirement: pipのcacheを使用しない

`Download-PipPkgs.ps1`と`Download-PipPkgs-from-Project.ps1`は、pip呼び出しに`--no-cache-dir`を指定しなければならない（MUST）。一時download directoryと生成したrequirements fileは`OutputDir`配下に作成しなければならない（MUST）。

#### Scenario: user profileのpip cacheが使用できない

- **WHEN** 呼び出し元のpip cacheが容量制限で使用できない状態でscriptを実行する
- **THEN** scriptはuser profileのcacheを使用せず`pypi` directoryへpackage archiveを作成する
- **THEN** scriptは処理終了時に一時download directoryと生成したrequirements fileを削除する

### Requirement: DEB metadataの一時fileはOutputDir側に配置する

`Download-DEB.ps1`は、repositoryから取得した`Packages.gz`の一時fileを`OutputDir`配下に作成し、systemまたはuser profileの一時directoryを使用してはならない（MUST NOT）。

#### Scenario: Packages metadataを展開する

- **WHEN** scriptがDebianまたはUbuntu repositoryの`Packages.gz`を取得する
- **THEN** 一時gzip fileは`OutputDir`直下に作成される
- **THEN** 一時gzip fileは読み取り後に削除される

### Requirement: Hugging Face cacheはOutputDir側に限定する

`Download-HFRepo.ps1`と`Download-Docling.ps1`は、`HF_HOME`を`OutputDir/.hf-cache`へ設定した状態でHugging Face repositoryを取得しなければならない（MUST）。

#### Scenario: 呼び出し元がHF_HOMEを設定している

- **WHEN** 呼び出し元が`HF_HOME`をuser profile配下へ設定した状態でscriptを実行する
- **THEN** `hf download`は`OutputDir/.hf-cache`を使用する
- **THEN** scriptは終了時に呼び出し元の`HF_HOME`を復元する
