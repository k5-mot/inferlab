# Pre-download Scripts.

## ⚡️ Quick Start

```powershell
### 本プロジェクトに必要なパッケージをダウンロード.
$OutputDir = "<output-dir>"
$DownloadScripts = @(
    "Download-Difypkg.ps1",
    "Download-Nextcloud.ps1",
    "Download-Docling.ps1",
    "Download-HFRepo.ps1",
    "Download-RPM.ps1",
    "Download-DEB.ps1",
    "Download-VSIX.ps1",
    "Download-DockerImages.ps1",
    "Download-PipPkgs.ps1",
    "Download-NpmPkgs.ps1"
)
foreach ($Script in $DownloadScripts) {
    powershell -ExecutionPolicy "Bypass" -Scope "Process" -File $Script -OutputDir $OutputDir
}

### pyproject.toml/requirements.txt を元に、
### <output-dir>/pypi/*.whl へダウンロード.
powershell -ExecutionPolicy "Bypass" -Scope "Process" -File "./Download-PipPkgs-from-Project.ps1" -OutputDir $OutputDir -ProjectDir "./py_pj/requirements.txt"

### package.json を元に、
### <output-dir>/npm/*.tgz へダウンロード.
powershell -ExecutionPolicy "Bypass" -Scope "Process" -File "./Download-NpmPkgs-from-Project.ps1" -OutputDir $OutputDir -ProjectDir "./ts_pj/package.json"
```

## 📁 Script Directory Structure

```bash
scripts/
├── Download-Difypkg.ps1
├── Download-Nextcloud.ps1
├── Download-Docling.ps1
├── Download-HFRepo.ps1
├── Download-RPM.ps1
├── Download-DEB.ps1
├── Download-VSIX.ps1
├── Download-DockerImages.ps1
├── Download-PipPkgs.ps1
├── Download-NpmPkgs.ps1
│
├── Download-PipPkgs-from-Project.ps1
├── Download-NpmPkgs-from-Project.ps1
│
└── tests/
```

## 📁 Output Directory Structure

```bash
<output-dir>/
├── dify/           # Download-Difypkg.ps1
│  │
│  ├── langgenius-openai_api_compatible_0.0.64.difypkg
│  ├── langgenius-ollama_1.0.0.difypkg
│  ├── langgenius-huggingface_tei_0.1.10.difypkg
│  ├── langgenius-cohere_0.0.17.difypkg
│  │
│  ├── langgenius-json_process_0.0.7.difypkg
│  ├── langgenius-mineru_0.5.7.difypkg
│  ├── langgenius-firecrawl_0.2.2.difypkg
│  ├── langgenius-regex_0.0.8.difypkg
│  ├── langgenius-dify_extractor_0.1.0.difypkg
│  ├── langgenius-general_chunker_0.0.13.difypkg
│  ├── langgenius-parentchild_chunker_0.0.13.difypkg
│  ├── langgenius-comfyui_0.3.11.difypkg
│  ├── langgenius-searxng_0.0.12.difypkg
│  ├── langgenius-chart_0.0.8.difypkg
│  ├── langgenius-qa_chunk_0.0.13.difypkg
│  ├── langgenius-stablediffusion_0.0.7.difypkg
│  ├── langgenius-qrcode_0.1.6.difypkg
│  ├── langgenius-podcast_generator_0.0.11.difypkg
│  ├── langgenius-gitlab_0.0.13.difypkg
│  ├── langgenius-devdocs_0.0.8.difypkg
│  ├── langgenius-unstructured_0.0.11.difypkg
│  ├── langgenius-oracle_ai_db_0.0.8.difypkg
│  │
│  ├── langgenius-firecrawl_datasource_0.2.13.difypkg
│  ├── langgenius-gitlab_datasource_0.3.12.difypkg
│  ├── langgenius-github_datasource_0.4.7.difypkg
│  ├── langgenius-aws_s3_storage_0.3.12.difypkg
│  ├── langgenius-brightdata_datasource_0.1.10.difypkg
│  ├── shenfor-minio_s3_storage_0.0.1.difypkg
│  │
│  ├── langgenius-github_trigger_1.5.0.difypkg
│  ├── langgenius-rsshub_trigger_0.1.0.difypkg
│  │
│  ├── langgenius-agent_0.0.47.difypkg
│  ├── langgenius-self_refine_agent_0.0.2.difypkg
│  │
│  ├── langgenius-oaicompat_dify_app_0.0.15.difypkg
│  └── langgenius-oaicompat_dify_model_0.0.10.difypkg
│
├── nextcloud/      # Download-Nextcloud.ps1
│  └── user_oidc-v8.10.1.tar.gz
│
├── docling/        # Download-Docling.ps1
│  ├── docling-project--docling-models
│  ├── docling-project--docling-layout-heron/
│  ├── docling-project--docling-layout-heron-101/
│  ├── docling-project--TableFormerV2/
│  ├── docling-project--DocumentFigureClassifier-v2.5/
│  ├── ibm-granite--granite-docling-258M/
│  ├── HuggingFaceTB--SmolVLM-256M-Instruct/
│  ├── docling-project--CodeFormulaV2/
│  └── tesseract/
│     ├── eng.traineddata
│     ├── jpn.traineddata
│     ├── jpn_vert.traineddata
│     ├── osd.traineddata
│     └── script/
│        ├── Japanese.traineddata
│        └── Japanese_vert.traineddata
│
├── hfrepo/         # Download-HFRepo.ps1
│  ├── Qwen--Qwen3.8-27B-FP8
│  ├── Qwen--Qwen3-Embedding-0.6B
│  ├── Qwen--Qwen3-Reranker-0.6B
│  ├── cl-nagoya--ruri-v3-310m
│  └── cl-nagoya--ruri-v3-reranker-310m
│
├── rpm/            # Download-RPM.ps1
│  ├── *.rpm
│  └── ...
│
├── deb/            # Download-DEB.ps1
│  ├── *.deb
│  └── ...
│
├── vscode/         # Download-VSIX.ps1
│  ├── *.vsix
│  └── ...
│
├── docker/         # Download-DockerImages.ps1
│  ├── docker.io_library_nginx_1.31.4-trixie-perl.tar
│  ├── ghcr.io_open-webui_open-webui_0.11.1.tar
│  ├── quay.io_docling-project_docling-serve_v1.31.0.tar
│  ├── *.tar
│  └── ...
│
├── pypi/           # Download-PipPkgs.ps1
│  ├── *.whl
│  └── ...
│
└── npm/            # Download-NpmPkgs.ps1
   ├── *.tgz
   └── ...
```
