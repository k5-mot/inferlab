# tinyloader

容量制限の厳しいオンライン環境で OCI イメージを少しずつ取得し、オフラインの Linux 環境で `docker load` できる tar に変換するためのスクリプト集です。

`docker pull` や `docker save` を直接使えない環境でも、registry API から manifest と blob を順番に取得して持ち出せるようにしています。

## 想定している使い方

- オンライン環境
  - Windows 11
  - WSL を使えない
  - Docker / Podman を使えない
  - Disk Quota が厳しい
  - Cygwin 上で bash を実行できる
- オフライン環境
  - Linux
  - Docker がインストールされている
  - 十分なストレージがある

## スクリプト一覧

### `download.sh`

レジストリから OCI manifest と blob を直接取得します。

- `state.json` で進捗を管理します
- 指定サイズを超えそうになったら停止し、blob の退避を促します
- 同じコマンドを再実行すると、前回の続きから再開します
- `docker.io`、`ghcr.io`、`quay.io`、`public.ecr.aws` のような public registry を想定しています

必要コマンド:

- `bash`
- `curl`
- `jq`
- `sha256sum`
- `awk`

### `convert.sh`

`download.sh` が作った `out/<image>/` を元に、`docker load -i` できる tar を `archive/` に生成します。

- 入力は `manifest.json` と `blobs/sha256/*` です
- 出力は Docker が読み込める OCI layout tar です
- 必要な blob が不足している場合は tar を作らずに停止します

必要コマンド:

- `bash`
- `jq`
- `tar`
- `sha256sum`
- `awk`

### `test.sh`

`download.sh` と `convert.sh` を通しで試すためのテストスクリプトです。

- 実運用と同じく `out/` と `archive/` を使います
- `download.sh` が容量超過で停止したら、blob を一時退避して自動で再開します
- 必要なら最後に `docker load` まで実行します

必要コマンド:

- `bash`
- `jq`
- `docker` (`--skip-load` を付けない場合)

## クイックスタート

### 1. オンライン環境で取得する

```bash
bash download.sh \
  --image-ref "docker.io/vllm/vllm-openai:v0.19.1" \
  --platform "linux/amd64" \
  --part-size-gb 4
```

容量上限に達すると停止して、次のようなメッセージを出します。

```text
ALERT: local blob usage reached the configured limit.
Move the files under .../out/<image>/blobs/sha256 to your temporary storage, keep state.json and manifest.json in place, then rerun the same command.
```

このときは `out/<image>/blobs/sha256/` の blob を別の場所に移し、同じコマンドを再実行してください。`state.json` と `manifest.json` はそのまま残します。

すべての取得が終わると `Complete` が表示されます。

### 2. オフライン環境へ移す

オンライン環境で取得した以下をまとめてオフライン環境へ持ち込みます。

- `out/<image>/state.json`
- `out/<image>/manifest.json`
- `out/<image>/blobs/sha256/*`

### 3. オフライン環境で tar を作る

```bash
bash convert.sh \
  --image-ref "docker.io/vllm/vllm-openai:v0.19.1"
```

成功すると、次のような tar ができます。

```text
archive/docker.io_vllm_vllm-openai_v0.19.1.tar
```

### 4. Docker にロードする

```bash
tar -tf archive/docker.io_vllm_vllm-openai_v0.19.1.tar
docker load -i archive/docker.io_vllm_vllm-openai_v0.19.1.tar
```

## テスト方法

通常の通し確認:

```bash
bash test.sh \
  --image-ref "docker.io/vllm/vllm-openai:v0.19.1" \
  --platform "linux/amd64" \
  --part-size-gb 4
```

容量超過での停止と再開も含めて確認したい場合:

```bash
bash test.sh \
  --image-ref "docker.io/vllm/vllm-openai:v0.19.1" \
  --platform "linux/amd64" \
  --part-size-gb 3.5 \
  --skip-load
```

`test.sh` は内部的に `.test-stash/` を使って blob の退避と復元を自動化しますが、完了後には削除します。

## ディレクトリ構成

```text
script/tinyloader/
├── download.sh
├── convert.sh
├── test.sh
├── out/
│   └── <image>/
│       ├── state.json
│       ├── manifest.json
│       └── blobs/
│           └── sha256/
│               ├── <digest1>
│               ├── <digest2>
│               └── ...
└── archive/
    └── <image>.tar
```

`<image>` はイメージ参照を安全なファイル名に変換したものです。たとえば `docker.io/vllm/vllm-openai:v0.19.1` は `docker.io_vllm_vllm-openai_v0.19.1` になります。

## 制約

- `download.sh` のサイズ判定は「今ローカルに残っている blob の合計サイズ」です
- 単一 blob 自体が `--part-size-gb` を超える場合、この方式では分割できないため停止します
- `convert.sh` を実行する前に、必要な blob 一式が `out/<image>/blobs/sha256/` に揃っている必要があります
- digest 指定のイメージ参照も扱えますが、`docker load` 後の tag は自動では付きません
