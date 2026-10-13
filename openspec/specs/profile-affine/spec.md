# `affine` profile Specification

## Purpose

Docker Composeの`affine` profileが利用者と運用者へ提供する能力、公開境界、依存関係、正常性の判定を現行コードに基づいて定めます。

## Requirements

### Requirement: affine profileの提供範囲

`affine` profileは`affine`、`affine-migration`、`affine-postgres`、`affine-redis`、`affine-caddy`を対象とし、HTTPSで利用できるknowledge workspaceと永続data storeを提供するものとする（MUST）。

#### Scenario: profileを選択する

- **WHEN** 運用者が`affine` profileを選択してCompose設定を解決する
- **THEN** AFFiNE、migration、PostgreSQL、Redis、Caddyがprofileの対象serviceとして含まれる
- **THEN** migration完了後にAFFiNEが起動し、Caddyを経由して接続できる

### Requirement: affine profileの公開境界

`affine` profileは、CaddyのHTTPS endpointだけをhostのTCP port `33500`で公開するものとする（MUST）。

#### Scenario: 利用者がAFFiNEへ接続する

- **WHEN** profileのserviceが起動してhealth判定に成功する
- **THEN** `https://${PUBLIC_HOST}:33500`からAFFiNEへ接続できる
- **THEN** AFFiNE、PostgreSQL、Redisをhostへ直接公開しない

### Requirement: affine profileのTLS

`affine` profileはCaddyのlocal CAで`PUBLIC_HOST`用の証明書を発行し、CaddyからAFFiNEまでは`internal-nw`上でproxyするものとする（MUST）。

#### Scenario: HTTPSを利用する

- **WHEN** 利用端末がCaddyのlocal CAを信頼し、`PUBLIC_HOST`と一致するURLへ接続する
- **THEN** browserは接続をsecure contextとして扱う
- **THEN** AFFiNEへforwardされるrequestは外向きURLとしてHTTPSを使用する
