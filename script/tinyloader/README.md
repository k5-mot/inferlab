# tinyloader

Docker / Podman / WSL を使えない Windows 環境で、`regctl image export` の出力を固定サイズの `Part*.tar` に分割するための補助スクリプトです。

Windows 側では 1 回の実行で Part を 1 個だけ作ります。ユーザがその Part を Samba ファイルサーバへ手動で移動し、もう一度 `download.ps1` を実行すると次の Part を作ります。

## regctl の準備

```powershell
Invoke-WebRequest `
  -Uri "https://github.com/regclient/regclient/releases/download/v0.11.3/regctl-windows-amd64.exe" `
  -OutFile "regctl.exe"
```

## Windows 側の手順

初回:

```powershell
.\download.ps1 `
  -ImageRef "docker.io/vllm/vllm-openai:v0.19.1" `
  -PartSizeGB 4 `
  -RegctlPath ".\regctl.exe"
```

`download.ps1` と同じディレクトリ直下にイメージ名+タグのサブディレクトリが作成され、Part はその中に出力されます。

```text
<download.ps1 のディレクトリ>\vllm_vllm-openai_v0.19.1\
  .download-state.json
  vllm_vllm-openai_v0.19.1_Part1.tar
```

`Part1.tar` をユーザが手動で Samba ファイルサーバへ移動します。

その後、同じコマンドを再実行します。

```powershell
.\download.ps1 `
  -ImageRef "docker.io/vllm/vllm-openai:v0.19.1" `
  -PartSizeGB 4 `
  -RegctlPath ".\regctl.exe"
```

前回の Part がローカルから消えていれば、`.download-state.json` が更新され、次の Part が作成されます。

```text
vllm_vllm-openai_v0.19.1_Part2.tar
```

これを繰り返します。

```text
download.ps1 実行 -> Part1 を手動移動
download.ps1 実行 -> Part2 を手動移動
download.ps1 実行 -> Part3 を手動移動
...
```

最後の Part を移動したあと、もう一度 `download.ps1` を実行すると完了状態になります。

## パラメータ

| パラメータ | 説明 |
| --- | --- |
| `-ImageRef` | 取得するイメージ参照。例: `docker.io/vllm/vllm-openai:v0.19.1` |
| `-PartSizeGB` | 1 Part の最大サイズ GB。Windows 側の quota より十分小さくします。 |
| `-RegctlPath` | `regctl.exe` のパス。省略時は `.\regctl.exe`。 |
| `-ProgressIntervalMB` | 進捗表示間隔 MB。既定値は `256`。 |
| `-SkipOciValidation` | 初回の OCI 検証を省略します。 |
| `-OciMetadataMaxMB` | 検証時にメモリ保持する JSON/blob メタデータ上限 MB。既定値は `16`。 |
| `-ResetState` | Part が残っていない場合に `.download-state.json` を作り直します。 |

## OCI 検証

既定では初回だけ、Part 作成前に `regctl image export` を一度ストリーム読み捨てし、OCI layout と layer blob を検証します。巨大な完全 tar は保存しません。

検証内容:

- tar ヘッダ checksum と危険なパスの検出
- `oci-layout`, `index.json` の存在と JSON 構造
- `manifest.json` が含まれる export の場合は、その JSON 構造
- `blobs/sha256/<digest>` の SHA256 一致
- `index.json` と OCI image manifest の参照先 blob 存在確認
- `manifest.json` の `Layers` が OCI blob path を指していること

通信量を抑えたい場合は省略できます。

巨大イメージでは registry 側の一時的な接続断が起きることがあります。`download.ps1` は `regctl` 子プロセスで HTTP/1.1 を優先し、ストリーム断時は未完成の Part を削除して同じ Part 作成を数回だけ再試行します。

```powershell
.\download.ps1 `
  -ImageRef "docker.io/vllm/vllm-openai:v0.19.1" `
  -PartSizeGB 4 `
  -RegctlPath ".\regctl.exe" `
  -SkipOciValidation
```

タグが更新される可能性を避けたい場合は、可能なら digest 形式の `ImageRef` を使ってください。

```text
docker.io/vllm/vllm-openai@sha256:<digest>
```

## GPU サーバ側の手順

ファイルサーバから GPU サーバへ、すべての Part を同じディレクトリへ配置します。

```text
/data/parts/
  vllm_vllm-openai_v0.19.1_Part1.tar
  vllm_vllm-openai_v0.19.1_Part2.tar
  vllm_vllm-openai_v0.19.1_Part3.tar
```

結合して `docker load` します。

```bash
./merge.sh /data/parts vllm_vllm-openai_v0.19.1
```

既定の出力先は次の形式です。

```text
/data/parts/vllm_vllm-openai_v0.19.1_FullPart.tar
```

明示的に出力先を指定する場合:

```bash
./merge.sh --sha256 \
  /data/parts \
  vllm_vllm-openai_v0.19.1 \
  /data/vllm_vllm-openai_v0.19.1_FullPart.tar
```

`merge.sh` は `sort -V` で Part を並べ、`Part1` から連番になっていることを確認します。欠損、空 Part、既存出力ファイルがある場合は停止します。既存 tar を上書きしたい場合は `--force` を指定してください。

Docker に load せず、結合だけ確認する場合:

```bash
./merge.sh --no-load --sha256 /data/parts vllm_vllm-openai_v0.19.1
```

Windows 側から WSL で動作確認する例:

```powershell
wsl.exe --exec ./merge.sh --no-load --sha256 /mnt/c/Temp/parts vllm_vllm-openai_v0.19.1
```

## test.ps1

`test.ps1` はテスト用の最小 OCI tar と fake `regctl` を一時生成し、手動搬送フローを `Move-Item` で模擬して `download.ps1` と `merge.sh` を検証します。外部レジストリや Docker には依存しません。

```powershell
.\test.ps1
```

任意の実イメージを使って検証する場合は、ImageRef を引数に指定します。この場合は実際に registry から取得し、Part を結合した tar も作成します。

```powershell
.\test.ps1 "vllm/vllm-openai:v0.19.1"
```

Part サイズや regctl のパスを指定する例:

```powershell
.\test.ps1 "docker.io/library/hello-world:latest" `
  -PartSizeGB 1 `
  -RegctlPath ".\regctl.exe"
```

通信量を抑えたい検証では `download.ps1` 側の OCI 事前検証を省略できます。

```powershell
.\test.ps1 "vllm/vllm-openai:v0.19.1" -SkipOciValidation
```

テスト作業ディレクトリを残したい場合:

```powershell
.\test.ps1 -KeepWorkDir
```

## 注意点

- `download.ps1` は途中 Part を作るたびに停止します。Part を手動で移動してから再実行してください。
- ローカルに Part が残っている状態で再実行すると停止します。これは同時に複数 Part を保持しないための制御です。
- `.download-state.json` は小さい状態管理ファイルです。Part だけを移動し、このファイルは Windows 側に残してください。
- 2 回目以降の `download.ps1` は `regctl image export` を先頭から再実行し、作成済みバイト数を読み捨てて次の Part を作ります。完全 tar は保存しませんが、後半の Part ほど通信量と時間が増えます。
- Part 欠損や順序違いがあると、後続の merge / `docker load` は失敗します。
- `merge.sh` の通常実行は `docker load -i` まで行います。結合だけなら `--no-load` を使ってください。
