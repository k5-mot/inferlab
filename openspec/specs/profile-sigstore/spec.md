# `sigstore` profile Specification

## Purpose

Docker Composeの`sigstore` profileが利用者と運用者へ提供する能力、公開境界、依存関係、正常性の判定を現行コードに基づいて定めます。

## Requirements

### Requirement: sigstore profileの提供範囲

`sigstore` profileは、初期MVPとして`sigstore-init`、`fulcio`、`rekor`、`timestamp-authority`、`sigstore-trusted-root`、`sigstore-signing-config`、`sigstore-dist`を対象とし、GitLab CIのID tokenによるcosign keyless署名と検証を提供するものとする（MUST）。`36-sigstore/docker-compose.final.yml`を重ねた最終MVPでは、`ctlog`を追加し、Fulcio証明書のCertificate Transparency記録を提供するものとする（MUST）。

#### Scenario: 初期MVPのprofileを選択する

- **WHEN** 運用者が`sigstore` profileを選択してroot Compose設定を解決する
- **THEN** 初期MVPの7 serviceがprofileの対象serviceとして含まれる
- **THEN** `sigstore-dist`は定義済みhealthcheckによって正常性を判定できる

#### Scenario: 最終MVPのoverrideを重ねる

- **WHEN** 運用者が`docker-compose.yml`と`36-sigstore/docker-compose.final.yml`を指定して`sigstore` profileを解決する
- **THEN** `ctlog`が追加され、`trusted_root.json`へCT logが含まれる

### Requirement: sigstore profileの公開境界

`sigstore` profileは、FulcioをhostのTCP port `33600`、Rekorを`33601`、Timestamp Authorityを`33602`、trust materialとlog tileの静的配信を`33603`で公開するものとする（MUST）。CT logはhost portで公開しないものとする（MUST NOT）。

#### Scenario: GitLab CI jobが接続する

- **WHEN** profileのserviceが起動し、`sigstore-dist`がhealth判定に成功する
- **THEN** GitLab CI jobは`http://${PUBLIC_HOST}:33603/trust/`からtrust materialを取得できる
- **THEN** 秘密鍵は`sigstore-dist`から配信されない

### Requirement: sigstore profileの連携

`sigstore` profileは、`gitlab` profileのGitLabを唯一のOIDC issuerとし、`aud: sigstore`のID tokenを持つjobへだけ証明書を発行するものとする（MUST）。

#### Scenario: GitLab CI jobで署名と検証を行う

- **WHEN** jobが`36-sigstore/examples/gitlab-ci.yml`に従ってcosignで署名と検証を行う
- **THEN** 署名者のpipeline定義を示すidentityとGitLab issuerで`Verified OK`になる
- **THEN** 異なるidentityまたは改ざんされたartifactの検証は失敗する
- **THEN** credentialの実値をrepositoryへ保存しない
