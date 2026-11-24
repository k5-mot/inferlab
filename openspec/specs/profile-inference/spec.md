# `inference` profile Specification

## Purpose

Docker Composeの`inference` profileが利用者と運用者へ提供する能力、公開境界、依存関係、正常性の判定を現行コードに基づいて定めます。

## Requirements

### Requirement: inference profileの提供範囲

`inference` profileは`litellm`、`vllm-embedding`、`vllm-reranking`、`hermes-agent`、`openclaw`、`openclaw-init`、`qwenpaw`、`qwenpaw-init`、`kokoro`を対象とし、OpenAI互換LLM gateway、chat model、embedding、reranking、agent UI、音声合成をまとめて提供するものとする（MUST）。

#### Scenario: profileを選択する

- **WHEN** 運用者が`inference` profileを選択してCompose設定を解決する
- **THEN** `litellm`、`vllm-embedding`、`vllm-reranking`、`hermes-agent`、`openclaw`、`openclaw-init`、`qwenpaw`、`qwenpaw-init`、`kokoro`がprofileの対象serviceとして含まれる
- **THEN** 長期稼働serviceは定義済みhealthcheckによって正常性を判定できる

### Requirement: inference profileの公開境界

`inference` profileは、LiteLLMをhostのTCP port `31000`、agent UIを`31001`から`31003`で公開するものとする（MUST）。

#### Scenario: 利用者または依存serviceが接続する

- **WHEN** profileのserviceが起動してhealth判定に成功する
- **THEN** 定義された公開境界から提供機能へ接続できる
- **THEN** 未定義のhost portを追加で公開しない

### Requirement: inference profileの連携

`inference` profileは、LiteLLMがvLLMと外部providerを統合し、generationとerrorのtraceをLangfuseへ送信するものとする（MUST）。

#### Scenario: 連携先を利用する

- **WHEN** 必要なcredentialと依存serviceが利用可能である
- **THEN** profile固有の連携が定義された経路で成功する
- **THEN** credentialの実値をrepositoryへ保存しない

