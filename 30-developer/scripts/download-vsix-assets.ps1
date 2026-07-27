$ErrorActionPreference = "Stop"

# Visual Studio Code向けに取得する拡張機能を定義する。
$VsixExtensions = @(
    "github.copilot",
    "github.copilot-chat",
    "anthropic.claude-code",
    "openai.chatgpt",
    "foam.foam-vscode",
    "gitlab.gitlab-workflow",
    "biomejs.biome",
    "xabikos.JavaScriptSnippets",
    "crystal-spider.jsdoc-generator",
    "formulahendry.auto-rename-tag",
    "formulahendry.auto-close-tag",
    "dsznajder.es7-react-js-snippets",
    "wix.vscode-import-cost",
    "davidanson.vscode-markdownlint",
    "yzhang.markdown-all-in-one",
    "bierner.markdown-mermaid",
    "tamasfe.even-better-toml",
    "redhat.vscode-yaml"
)

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDirectory "download-assets-common.ps1")

$AssetsPath = Get-AssetsPath -ScriptDirectory $ScriptDirectory -CurrentDirectory (Get-Location).Path
Write-Host "assets directory: $AssetsPath"

New-AssetDirectories -AssetsPath $AssetsPath -Names @("vsix")
$VsixAssetsDir = Join-Path $AssetsPath "vsix"

Save-VsixExtensions -ExtensionIds $VsixExtensions -OutputDirectory $VsixAssetsDir
Assert-AssetFilesExist -Directory $VsixAssetsDir -Pattern "*.vsix" -Description "VSIX"
