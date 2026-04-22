# Codex CLI 引継ぎ資料

## 件名

Windows 制約環境で `regctl` を用いて巨大 Docker イメージを分割取得し、GPU サーバで復元する仕組みの実装

---

## 1. 背景 / 目的

ユーザ環境には以下制約があります。

### Windows PC（オンライン）

* Docker / Podman 利用不可
* WSL / Hyper-V 利用不可
* Disk Quota 制限あり
* **10GB を超える単一ファイルを保持できない**
* インターネット接続あり

### ファイルサーバ

* 256GB
* Windows PC から直接マウントされていない（ローカルパスとして扱えない）

### GPU サーバ（オフライン）

* NVIDIA GPU 搭載
* Docker 利用可能想定
* ネットワーク隔離環境

### 対象イメージ

`docker.io/vllm/vllm-openai:v0.19.1`

通常の `docker save` 相当 tar は 16GB 超となり、Windows PC 上で保存不能。

---

## 2. 採用方針

`regctl` を利用する。

理由:

* Docker デーモン不要
* Windows 単体実行可
* レジストリから直接取得可能
* `image export` で `docker load` 互換 tar を stdout 出力可能

公式:

* `regctl image export` は docker load 用 tar を stdout 出力
  ([regclient][1])

---

## 3. 最終成果物

Codex CLI に作成してほしい成果物は **2つ**。

### (1) download.ps1

Windows 用 PowerShell スクリプト

役割:

* `regctl image export` の stdout を受ける
* 指定サイズごとに分割保存
* `Part1.tar`, `Part2.tar` ... を作成
* 各 Part 完成後、任意のコピーコマンド実行
* コピー成功後、Windows ローカル Part を削除

### (2) merge.sh

GPU サーバ用 bash スクリプト

役割:

* すべての Part を結合
* 完全 tar を復元
* `docker load -i` 実行

---

## 4. download.ps1 要件（重要）

## 入力パラメータ例

```powershell
.\download.ps1 `
  -ImageRef "docker.io/vllm/vllm-openai:v0.19.1" `
  -PartSizeGB 4 `
  -OutputDir "C:\Temp\parts" `
  -RemoteCopyCommand "scp {file} user@fileserver:/upload/" `
  -RegctlPath "C:\Tools\regctl.exe"
```

---

## 必須仕様

### 4.1 分割方式

`regctl image export IMAGE -`

stdout をバイナリストリームで受け取り、固定サイズで:

* `vllm_vllm-openai_v0.19.1_Part1.tar`
* `vllm_vllm-openai_v0.19.1_Part2.tar`
* ...

保存する。

※ 実体は「tar 全体の連続バイト列の分割片」。

---

### 4.2 Quota 対策

同時にローカルに存在する Part は原則 1 個。

処理順:

1. Part1 作成完了
2. RemoteCopyCommand 実行
3. 成功なら Part1 削除
4. Part2 作成開始

---

### 4.3 コピーコマンドの置換

`{file}` を Part ファイルパスへ置換して実行。

例:

```powershell
scp {file} user@server:/upload/
```

↓

```powershell
scp C:\Temp\parts\xxx_Part1.tar user@server:/upload/
```

---

### 4.4 進捗表示

表示してほしい内容:

* 現在の Part 番号
* 現在 Part の書込 MB
* 総受信 GB（概算）
* コピー開始 / 完了
* 削除完了

---

### 4.5 異常系

* regctl 非存在 → エラー終了
* export 失敗 → 異常終了
* コピー失敗 → リトライ3回
* リトライ失敗 → 停止（Part は保持）
* 空ファイル生成時は削除

---

### 4.6 文字コード

PowerShell 5.1 / PowerShell 7 両対応を意識。

---

## 実装ヒント（重要）

PowerShell で `Start-Process` + `RedirectStandardOutput` より、
`.NET Process` で `StandardOutput.BaseStream.Read()` 推奨。

バッファ例:

```powershell
$buffer = New-Object byte[] 1048576
```

1MB単位で読み込み。

---

## 5. merge.sh 要件

入力例:

```bash
./merge.sh /data/parts vllm_vllm-openai_v0.19.1
```

ディレクトリ内:

* Part1.tar
* Part2.tar
* ...

処理:

```bash
cat ..._Part*.tar > vllm_vllm-openai_v0.19.1.tar
docker load -i vllm_vllm-openai_v0.19.1.tar
```

---

## 必須仕様

### 並び順保証

`sort -V` を使うこと。

### SHA256 任意対応

希望あれば:

```bash
sha256sum merged.tar
```

### エラー時停止

```bash
set -euo pipefail
```

---

## 6. 命名規則

ImageRef:

```text
docker.io/vllm/vllm-openai:v0.19.1
```

ファイル名ベース:

```text
vllm_vllm-openai_v0.19.1
```

変換ルール:

* `/` → `_`
* `:` → `_`

---

## 7. 実装優先順位

1. download.ps1（最優先）
2. merge.sh
3. README.md

---

## 8. README に書く内容

* regctl ダウンロード方法
* 実行例
* scp 利用例
* WinSCP CLI 利用例
* merge 手順
* docker load 手順
* 注意点（Part 欠損時は失敗）

---

## 9. 禁止事項

* WSL 前提実装
* Docker for Windows 前提
* 10GB 超単一ファイル一時生成
* GUI 必須

---

## 10. 期待する完成イメージ

Windows:

```powershell
.\download.ps1 ...
```

GPU:

```bash
./merge.sh /data/parts vllm_vllm-openai_v0.19.1
```

---

## 11. 補足技術情報

regctl は Docker 不要で OCI/Docker registry にアクセス可能。
image export は docker load 用 tar を生成する。

([regclient][1])

[1]: https://regclient.org/cli/regctl/image/export/?utm_source=chatgpt.com "regctl image export - regclient"
