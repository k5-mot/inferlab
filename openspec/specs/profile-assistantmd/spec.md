# `assistantmd` profile Specification

## Purpose

Docker Composeの`assistantmd` profileが利用者と運用者へ提供する能力、公開境界、永続化、正常性の判定を現行コードに基づいて定めます。

## Requirements

### Requirement: assistantmd profileの提供範囲

`assistantmd` profileは`assistantmd-init`と`assistantmd`を対象とし、Markdown-firstのAI agent workspace、owner login、vaultを提供するものとする（MUST）。

#### Scenario: profileを選択する

- **WHEN** 運用者が`assistantmd` profileを選択してCompose設定を解決する
- **THEN** `assistantmd-init`と`assistantmd`がprofileの対象serviceとして含まれる
- **THEN** 長期稼働serviceは定義済みhealthcheckによって正常性を判定できる

### Requirement: assistantmd profileの公開境界

`assistantmd` profileは、owner tokenで保護したWeb UIをhostのTCP port `32800`で公開し、Internetへ直接公開しないものとする（MUST）。

#### Scenario: 利用者が接続する

- **WHEN** profileのserviceが起動してhealth判定に成功する
- **THEN** hostのTCP port `32800`からWeb UIへ接続できる
- **THEN** 未定義のhost portを追加で公開しない

### Requirement: assistantmd profileの永続化

`assistantmd` profileは、vaultとsystem状態を別々のCompose volumeへ保存し、初回起動時に既定の`Workspace` vaultを作成するものとする（MUST）。

#### Scenario: containerを再作成する

- **WHEN** 運用者が永続volumeを維持して`assistantmd` containerを再作成する
- **THEN** vault、会話、設定、credentialが維持される
- **THEN** credentialの復号には同じ世代の`ASSISTANTMD_SECRETS_KEY`を使用する

### Requirement: assistantmd profileの連携

`assistantmd` profileは、`internal-nw`上のOpenAI互換providerとしてLiteLLMを設定できるものとする（MUST）。

#### Scenario: LiteLLMを利用する

- **WHEN** 利用者がAssistant.mdへLiteLLMのbase URL、API key、modelを設定する
- **THEN** Assistant.mdから`http://litellm:4000/v1`へ接続できる
- **THEN** credentialの実値をrepositoryへ保存しない
