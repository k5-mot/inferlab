# `zeroclaw` profile Specification

## Purpose

Docker Composeの`zeroclaw` profileが利用者と運用者へ提供する能力、公開境界、依存関係、正常性の判定を現行コードに基づいて定めます。

## Requirements

### Requirement: zeroclaw profileの提供範囲

`zeroclaw` profileは`zeroclaw`、`zeroclaw-init`を対象とし、ZeroClawのdashboard、Discord channel、persona、memory、sessionを提供するものとする（MUST）。

#### Scenario: profileを選択する

- **WHEN** 運用者が`zeroclaw` profileを選択してCompose設定を解決する
- **THEN** `zeroclaw`、`zeroclaw-init`がprofileの対象serviceとして含まれる
- **THEN** 長期稼働serviceは定義済みhealthcheckによって正常性を判定できる

### Requirement: zeroclaw profileの公開境界

`zeroclaw` profileは、ZeroClaw dashboardとgatewayをhostのTCP port `31003`で公開し、gateway pairingを必須とするものとする（MUST）。

#### Scenario: 利用者または依存serviceが接続する

- **WHEN** profileのserviceが起動してhealth判定に成功する
- **THEN** pairing済みのclientだけが定義された公開境界から提供機能へ接続できる
- **THEN** 未定義のhost portを追加で公開しない

### Requirement: zeroclaw profileの連携

`zeroclaw` profileは、LiteLLM providerの既定modelとfallback modelを設定し、requestをZeroClaw識別tag付きでLangfuseへ記録するものとする（MUST）。人格はGit管理fileをread-onlyで読み込むものとする（MUST）。

#### Scenario: 連携先を利用する

- **WHEN** 必要なcredentialと依存serviceが利用可能である
- **THEN** ZeroClawのmodel requestが`http://litellm:4000/v1`を経由して成功する
- **THEN** ZeroClawの応答が`10-inference/zeroclaw/persona`の人格fileに従う
- **THEN** credentialの実値をrepositoryへ保存しない
