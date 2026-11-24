# `openkb` profile Specification

## Purpose

Docker Composeの`openkb` profileが利用者と運用者へ提供する能力、公開境界、依存関係、正常性の判定を現行コードに基づいて定めます。

## Requirements

### Requirement: openkb profileの提供範囲

`openkb` profileは`couchdb`を対象とし、旧OpenKB連携との互換性のため、知識source保存用CouchDBを選択的に起動できるようにするものとする（MUST）。

#### Scenario: profileを選択する

- **WHEN** 運用者が`openkb` profileを選択してCompose設定を解決する
- **THEN** `couchdb`がprofileの対象serviceとして含まれる
- **THEN** 長期稼働serviceは定義済みhealthcheckによって正常性を判定できる

### Requirement: openkb profileの公開境界

`openkb` profileは、CouchDBをhostのTCP port `34000`で公開するものとする（MUST）。

#### Scenario: 利用者または依存serviceが接続する

- **WHEN** profileのserviceが起動してhealth判定に成功する
- **THEN** 定義された公開境界から提供機能へ接続できる
- **THEN** 未定義のhost portを追加で公開しない

### Requirement: openkb profileの連携

`openkb` profileは、`obsidian` profileと同じCouchDB serviceと永続dataを共有するものとする（MUST）。

#### Scenario: 連携先を利用する

- **WHEN** 必要なcredentialと依存serviceが利用可能である
- **THEN** profile固有の連携が定義された経路で成功する
- **THEN** credentialの実値をrepositoryへ保存しない

