# Doclingモデルbind mount構成調査（2026-08-24）

## 結論

Docling Serveは公式image `quay.io/docling-project/docling-serve:v1.30.0`を使用し、hostの`/srv/docling`を次の2領域へ分けてbind mountする構成を推奨する。

| host path | container path | 用途 | runtime mount |
|---|---|---|---|
| `/srv/docling` | `/opt/app-root/src/.cache/docling/models` | Doclingのlayout、table、OCR補助、enrichment model | read-only |
| `/srv/docling/tesseract` | `/usr/share/tesseract/tessdata` | Tesseractのlanguage・script traineddata | read-only |

Docling modelは、Docling Serve v1.30.0と互換性のある`docling-tools models download`と`docling-tools models download-hf-repo`を`uvx`経由でhost上から実行し、指定したmodelとHugging Face repositoryを事前配置する。Tesseract traineddataは、`tesseract-ocr/tessdata_best`のcommitを固定して取得する。取得scriptはDockerまたはWSLへ依存させず、PowerShell版は`uvx`と`Invoke-WebRequest`、Shell版は`uvx`と`curl`を使用する。

この構成ではbind mountがimage内の同一pathを隠す。host側が空または不完全な状態で起動してはならない（MUST NOT）。`DOCLING_SERVE_ARTIFACTS_PATH`と`TESSDATA_PREFIX`はmount先と完全に一致させなければならない（MUST）。

## 現行構成

調査開始時の`HEAD`では、`11-rag/docker-compose.yml`が`ghcr.io/k5-mot/docling-serve-jp:v1.30.0`を使用し、model pathを`/opt/app-root/src/.cache/docling/models`に設定している。modelとtraineddataはimage内にあり、host bind mountはない。`DOCLING_SERVE_LOAD_MODELS_AT_BOOT`は`false`である。

Open WebUIは`ocr_preset: "tesseract"`と`ocr_lang: ["jpn", "jpn_vert", "eng"]`を指定する。このため、現在の実行経路に必要なTesseract language fileは`jpn.traineddata`、`jpn_vert.traineddata`、`eng.traineddata`である。DoclingのTesserocr実装はorientation判定用に`osd` readerも初期化するため、`osd.traineddata`も配置する必要がある。

## Docling modelの事前配置

### modelの選択

Docling公式は、offline利用向けに`docling-tools models download`でmodelを事前取得し、DoclingまたはDocling Serveへartifacts pathを渡す方法を案内している。現行scriptではDocling Serve v1.30.0に含まれるDocling 2.118.0を`uvx --from docling==2.118.0`で一時環境へ導入して実行する。Docling Serveでは`DOCLING_SERVE_ARTIFACTS_PATH`を使用する。

Docling 2.118.0を含むDocling Serve v1.30.0に対して、今回指定するCLI model IDは次のとおりである。

| stage | model | CLI model ID |
|---|---|---|
| Layout | `docling-layout-heron` | `layout` |
| Table Structure | TableFormerとTableFormer v2 | `tableformer`、`tableformerv2` |
| Picture Classifier | `DocumentFigureClassifier-v2.5` | `picture_classifier` |
| VLM Convert | Granite-Docling-258M | `granitedocling` |
| Picture Description | SmolVLM-256M | `smolvlm` |
| Code & Formula | CodeFormulaV2 | `code_formula` |

Open WebUIからの変換ではTesseractを明示指定するため、英語・日本語traineddataを別途配置する。Docling Serve v1.30.0の起動時warm-upでOCR Autoを使用する場合はRapidOCRも必要になるため、既存の`RapidOcr` directoryは削除しない。

`--all`は⭐対象外のGranite Vision、SmolDocling、Nemotron OCRなども取得するため使用しない。model catalogと取得対象の対応をreview可能にするため、model IDを明示する。

### download手順

Docling Serve v1.30.0のruntime userはUID `1001`、GID `0`である。取得環境ではDocling CLIをuvx経由で実行し、`out/srv/docling/`へ配布先と同じtreeを作成する。

```bash
# 配布先と同じDocling directory treeを作成する。
mkdir -p out/srv/docling

# 指定したCLI modelをDocling公式CLIでdownloadする。
uvx --from docling==2.118.0 docling-tools models download \
  --output-dir out/srv/docling \
  layout tableformer tableformerv2 picture_classifier granitedocling smolvlm code_formula

# 指定したHugging Face repositoryをmodel directoryへdownloadする。
uvx --from docling==2.118.0 docling-tools models download-hf-repo \
  --output-dir out/srv/docling \
  docling-project/docling-layout-heron \
  docling-project/docling-layout-heron-101 \
  docling-project/DocumentFigureClassifier-v2.5 \
  docling-project/CodeFormulaV2
```

期待結果:

- 指定した7つのDocling CLI model IDのdownloadが成功する。
- `out/srv/docling/`直下に指定した4つのHugging Face repository directoryが作られる。
- download commandが0で終了する。
- UID `1001`のcontainer processから全directoryとfileを読み取れる。

失敗条件:

- hostの空き容量不足またはHugging Faceへの接続errorでdownloadが中断する。
- 保存先のpermissionによりmodelを書き込めない。
- downloadに使用したDocling CLIとruntime image内Doclingのversionに互換性がない。

### EasyOCRとlocal VLMを追加する場合

EasyOCRまたはlocal VLMは必要になった時点で明示的に追加する。同じoutput directoryを指定すれば、既存modelを保持したまま不足分を追加できる。

```bash
# 日本語と英語向けEasyOCR modelを既存のmodel directoryへ追加する。
uvx --from docling==2.118.0 docling-tools models download \
  --output-dir out/srv/docling \
  easyocr --easyocr-lang ja --easyocr-lang en

# Granite Doclingをlocal VLMとして使用する場合だけmodelを追加する。
uvx --from docling==2.118.0 docling-tools models download \
  --output-dir out/srv/docling granitedocling
```

## Tesseract traineddataの事前配置

### 推奨sourceとrevision

高精度を優先し、`tesseract-ocr/tessdata_best`を使用する。再現性のため、2026-08-24時点の`main`であるcommit `e12c65a915945e4c28e237a9b52bc4a8f39a0cec`へ固定する。`tessdata_best`はTesseract 4以降のLSTM engine専用であり、legacy engine mode 0または2では使用できない。

| path | 用途 | 現行構成での必要性 |
|---|---|---|
| `eng.traineddata` | 英語 | 必須 |
| `jpn.traineddata` | 横書きを含む日本語 | 必須 |
| `jpn_vert.traineddata` | 日本語縦書き | 必須 |
| `osd.traineddata` | orientation and script detection | 必須 |
| `script/Japanese.traineddata` | Japanese script全般 | 将来用 |
| `script/Japanese_vert.traineddata` | Japanese scriptの縦書き | 将来用 |

現在の`ocr_lang`は`jpn`、`jpn_vert`、`eng`であり、`script/Japanese`を直接指定しない。それでもscript modelをhostへ含めておけば、language個別modelではなくscript modelへ切り替えるときにimageを作り直す必要がない。script fileは`script/`というsubdirectory構造を維持しなければならない（MUST）。

### download手順

```bash
# Tesseract languageとscript modelの保存directoryを作成する。
mkdir -p out/srv/docling/tesseract/script

# 英語の高精度traineddataを固定revisionから取得する。
curl --fail --silent --show-error --location \
  --output out/srv/docling/tesseract/eng.traineddata \
  https://raw.githubusercontent.com/tesseract-ocr/tessdata_best/e12c65a915945e4c28e237a9b52bc4a8f39a0cec/eng.traineddata

# 日本語の高精度traineddataを固定revisionから取得する。
curl --fail --silent --show-error --location \
  --output out/srv/docling/tesseract/jpn.traineddata \
  https://raw.githubusercontent.com/tesseract-ocr/tessdata_best/e12c65a915945e4c28e237a9b52bc4a8f39a0cec/jpn.traineddata

# 日本語縦書きの高精度traineddataを固定revisionから取得する。
curl --fail --silent --show-error --location \
  --output out/srv/docling/tesseract/jpn_vert.traineddata \
  https://raw.githubusercontent.com/tesseract-ocr/tessdata_best/e12c65a915945e4c28e237a9b52bc4a8f39a0cec/jpn_vert.traineddata

# orientation and script detection用traineddataを固定revisionから取得する。
curl --fail --silent --show-error --location \
  --output out/srv/docling/tesseract/osd.traineddata \
  https://raw.githubusercontent.com/tesseract-ocr/tessdata_best/e12c65a915945e4c28e237a9b52bc4a8f39a0cec/osd.traineddata

# Japanese script modelをsubdirectory構造を維持して取得する。
curl --fail --silent --show-error --location \
  --output out/srv/docling/tesseract/script/Japanese.traineddata \
  https://raw.githubusercontent.com/tesseract-ocr/tessdata_best/e12c65a915945e4c28e237a9b52bc4a8f39a0cec/script/Japanese.traineddata

# Japanese vertical script modelをsubdirectory構造を維持して取得する。
curl --fail --silent --show-error --location \
  --output out/srv/docling/tesseract/script/Japanese_vert.traineddata \
  https://raw.githubusercontent.com/tesseract-ocr/tessdata_best/e12c65a915945e4c28e237a9b52bc4a8f39a0cec/script/Japanese_vert.traineddata

# traineddataが配布前に読み取り可能であることを確認する。
find out/srv/docling/tesseract -type f -readable
```

期待結果:

- 6個のtraineddataが上表のdirectory構造で存在する。
- Tesseractのlanguage一覧に`eng`、`jpn`、`jpn_vert`、`osd`、`script/Japanese`、`script/Japanese_vert`が表示される。

失敗条件:

- downloadがHTTP errorで終了する。
- `script/`を除去してfileを平坦化する。
- `TESSDATA_PREFIX`がtraineddataを置いたdirectoryと一致しない、または末尾の`/`がない。

## Composeへの反映値

```yaml
services:
  docling:
    image: quay.io/docling-project/docling-serve:v1.30.0
    environment:
      DOCLING_SERVE_ARTIFACTS_PATH: /opt/app-root/src/.cache/docling/models
      DOCLING_ARTIFACTS_PATH: /opt/app-root/src/.cache/docling/models
      TESSDATA_PREFIX: /usr/share/tesseract/tessdata/
      HF_HUB_OFFLINE: "1"
      TRANSFORMERS_OFFLINE: "1"
    volumes:
      - /srv/docling:/opt/app-root/src/.cache/docling/models:ro
      - /srv/docling/tesseract:/usr/share/tesseract/tessdata:ro
```

`DOCLING_SERVE_ARTIFACTS_PATH`はDocling Serveが各converterへ渡すmodel rootであり、必須である。`DOCLING_ARTIFACTS_PATH`はDocling libraryを直接起動するtoolとの一貫性を持たせるため同じ値にする。`HF_HUB_OFFLINE=1`と`TRANSFORMERS_OFFLINE=1`は、model不足時にnetwork downloadへfallbackせず明確に失敗させるため設定する。

`DOCLING_SERVE_LOAD_MODELS_AT_BOOT=true`にするとdefault converterを起動時にwarm upするため、不足modelを早期検出できる。一方で起動時間とmemory使用量が増える。現行値`false`を維持する場合、`/readyz`成功だけでは実際のconversionに必要な全modelを読み込めることを証明できない。deployment後に実fileのconversion testを必ず実施しなければならない（MUST）。

`DOCLING_SERVE_ENABLE_REMOTE_SERVICES`はexternal VLM APIなどを許可する設定であり、Docling modelのdownload可否を直接制御するものではない。現在のpicture descriptionをLiteLLMへoffloadする場合は`true`を維持できる。model offline化の制御にはHugging FaceとTransformersのoffline環境変数を使用する。

## permissionとread-only可否

公式Docling Serve v1.30.0はUID `1001`、GID `0`で実行される。modelとtraineddataは推論時に読み取り対象であり、事前配置が完全ならruntime bind mountはread-onlyにできる。directoryは少なくとも`0755`、fileは少なくとも`0644`とし、UID `1001`からpath traversalとreadが可能でなければならない（MUST）。

read-only mountには次の運用上の利点がある。

- 欠落modelをruntimeが暗黙にdownloadして構成を変えることを防げる。
- container再起動によるhost artifactの変更を防げる。
- model更新を事前配置手順へ限定できる。

一方、model追加やversion更新は稼働中のread-only mountへ直接行わず、staging directoryへdownloadして検証後に切り替える方が安全である。少なくとも更新前に`/srv/docling`のbackupまたはsnapshotを取得する。

## Docling Serve JP固有の挙動

`ghcr.io/k5-mot/docling-serve-jp:v1.30.0`は公式Docling Serve imageに次の内容を追加する派生imageである。

- `tesseract-langpack-jpn`を追加する。
- `tessdata_best`の`jpn`、`jpn_vert`、`eng`でpackage付属dataを上書きする。
- `TESSDATA_PREFIX`を`/usr/share/tesseract/tessdata/`へ設定する。
- Docling modelをimage build時に取得する。
- `HF_HUB_OFFLINE=1`と`TRANSFORMERS_OFFLINE=1`をimageへ設定する。

実際のv1.30.0 imageを確認すると、languageは`eng`、`jpn`、`jpn_vert`、`osd`の4つであり、Docling model directoryは約702 MiBであった。model rootにはlayout、tableformer系、picture classifierが存在した。一方、派生repositoryのREADMEに記載される`code_formula`と、公式v1.30.0 imageに存在する`RapidOcr`、`EasyOcr`は確認できなかった。READMEだけでartifactの完全性を判断してはならない（MUST NOT）。

host bind mountへ移行すると、派生imageに焼き込まれたmodelとtraineddataはmount元によって隠れる。そのため、派生imageを継続使用してもhost側の事前配置は省略できない。公式imageに切り替え、必要artifactをhost側でrevision管理する方が責務が明確になる。

## 検証手順

```bash
# Composeがmountと環境変数を解決できることを確認する。
sudo docker compose --env-file .env --profile rag config --quiet

# Docling containerからhost配置model directoryの内容を確認する。
sudo docker compose --env-file .env --profile rag run --rm --no-deps \
  --entrypoint sh docling -lc \
  'test -r "$DOCLING_SERVE_ARTIFACTS_PATH/docling-project--docling-models/config.json"'

# Tesseractがbind mountしたlanguageとscriptを認識することを確認する。
sudo docker compose --env-file .env --profile rag run --rm --no-deps \
  --entrypoint tesseract docling --list-langs

# Doclingを起動してhealth状態を確認する。
sudo docker compose --env-file .env --profile rag up -d docling

# 実際のmodel load errorとoffline fallback errorがないことを確認する。
sudo docker compose --env-file .env --profile rag logs --no-log-prefix docling
```

期待結果:

- Compose validationが成功する。
- modelの代表fileをUID `1001`から読み取れる。
- Tesseract language一覧に配置した6項目が表示される。
- Doclingがhealthyになり、日本語PDFのconversionが成功する。
- logにHugging Face download試行、missing model、traineddata errorが出ない。

失敗条件:

- bind source directoryが存在しない、空、またはpermission errorになる。
- `tesseract --list-langs`に`jpn`、`jpn_vert`、`eng`、`osd`がない。
- model load時にoffline cache missまたはread-only filesystem errorが出る。
- `/readyz`は成功するが、実file conversionがmodel不足で失敗する。

## 更新方針

Docling Serveを更新するときは、先に新tagと同じimageで別のstaging directoryへmodelをdownloadする。新旧versionが同じhost model directoryを安全に共有できると仮定してはならない（MUST NOT）。model directoryの切り替え、Composeのimage tag更新、conversion testを同じ変更単位で行う。

Tesseract traineddataはcommit SHAを明示的に更新する。浮動する`main` URLを運用手順へ使用せず、対象fileの存在とTesseractによる認識を更新ごとに検証する。

## References

- [uv: Using tools](https://docs.astral.sh/uv/guides/tools/)
- [Docling: Advanced options - Model prefetching and offline usage](https://docling-project.github.io/docling/usage/advanced_options/)
- [Docling: `docling-tools` CLI reference](https://docling-project.github.io/docling/reference/cli/)
- [Docling: Model catalog](https://github.com/docling-project/docling/blob/main/docs/usage/model_catalog.md)
- [Hugging Face: docling-layout-heron](https://huggingface.co/docling-project/docling-layout-heron)
- [Hugging Face: docling-layout-heron-101](https://huggingface.co/docling-project/docling-layout-heron-101)
- [Hugging Face: DocumentFigureClassifier-v2.5](https://huggingface.co/docling-project/DocumentFigureClassifier-v2.5)
- [Hugging Face: CodeFormulaV2](https://huggingface.co/docling-project/CodeFormulaV2)
- [Docling: Installation - OCR engines](https://docling-project.github.io/docling/getting_started/installation/)
- [Docling: Pipeline options](https://docling-project.github.io/docling/reference/pipeline_options/)
- [Docling Serve v1.30.0: Containerfile](https://github.com/docling-project/docling-serve/blob/v1.30.0/Containerfile)
- [Docling Serve v1.30.0: Configuration](https://github.com/docling-project/docling-serve/blob/v1.30.0/docs/configuration.md)
- [Docling Serve v1.30.0: OS packages](https://github.com/docling-project/docling-serve/blob/v1.30.0/os-packages.txt)
- [Docling Serve: missing Tesseract OSD fix](https://github.com/docling-project/docling-serve/pull/263)
- [Docling Serve JP: Dockerfile](https://github.com/k5-mot/docling-serve-jp/blob/main/Dockerfile)
- [Docling Serve JP: External model mount manual](https://github.com/k5-mot/docling-serve-jp/blob/main/MANUAL.md)
- [Tesseract: tessdata_best README at pinned revision](https://github.com/tesseract-ocr/tessdata_best/blob/e12c65a915945e4c28e237a9b52bc4a8f39a0cec/README.md)
- [Tesseract: Traineddata files for version 4 and later](https://tesseract-ocr.github.io/tessdoc/Data-Files.html)
- [Tesseract: Command-line usage](https://tesseract-ocr.github.io/tessdoc/Command-Line-Usage.html)
