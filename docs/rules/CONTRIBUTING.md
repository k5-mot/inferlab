# コントリビューションルール

## Gitブランチ戦略

このprojectはGitHub Flowを採用する。

### 基本原則

- `main`は常にrelease可能な状態でなければならない（MUST）。
- すべての変更branchは、最新の`main`から作成しなければならない（MUST）。
- `main`へ直接pushしてはならない（MUST NOT）。変更はPull Requestを経由しなければならない（MUST）。
- `develop`、`release/*`などの長期branchを新設してはならない（MUST NOT）。既存の`develop`は新規開発の起点として使用してはならない（MUST NOT）。
- branchは1つの目的だけを扱い、短期間でmergeできる大きさに保つべきである（SHOULD）。

### ブランチ名

branch名は`<category>/<short-description>`形式とし、`short-description`には小文字ASCIIとhyphenを使用しなければならない（MUST）。

| カテゴリー | 用途 | 例 |
| --- | --- | --- |
| `feature` | 新機能 | `feature/add-model-router` |
| `fix` | 不具合修正 | `fix/restore-docker-dns` |
| `docs` | documentationのみ | `docs/network-runbook` |
| `refactor` | 外部仕様を変えない再構成 | `refactor/webui-layout` |
| `perf` | 性能改善 | `perf/reduce-tei-memory` |
| `test` | test追加・修正 | `test/docling-params` |
| `build` | build・dependency・package | `build/update-base-image` |
| `ci` | CI/CD | `ci/add-compose-validation` |
| `chore` | 上記に該当しない保守 | `chore/refresh-tooling` |
| `hotfix` | productionの緊急修正 | `hotfix/recover-egress-route` |

### 開発フロー

1. 最新の`main`を取得し、目的に対応するbranchを作成する。
2. 変更を論理単位でcommitし、各commitで必要なbuildとtestを成功させる。
3. branchをremoteへpushし、早い段階でPull Requestを作成する。
4. CI、review、必要な動作確認を完了する。
5. 承認後に`main`へmergeする。途中の修正commitが作業履歴にすぎない場合はsquash mergeを使用すべきである（SHOULD）。
6. merge後はremoteとlocalの作業branchを削除すべきである（SHOULD）。

緊急修正でも上記flowを省略してはならない（MUST NOT）。`hotfix/*`を`main`から作成し、通常より小さいPull Requestとして処理する。

## コミットルール

### コミットメッセージ

commit messageは、gitmojiをprefixとするConventional Commits形式で記述しなければならない（MUST）。

```text
<gitmoji> <type>(<scope>)!?: <subject>
```

- `<scope>`は任意とする（OPTIONAL）。
- `<subject>`は日本語、50文字以内で記述し、句点`。`で終えてはならない（MUST）。
- 理由や移行上の注意がsubjectだけでは分からない場合、空行の後にbodyを記述すべきである（SHOULD）。
- issueや破壊的変更はfooterへ記述しなければならない（MUST）。
- 破壊的変更ではtypeまたはscopeの直後へ`!`を付け、`BREAKING CHANGE:` footerを記述しなければならない（MUST）。

### コミット粒度

- 1 commitは1つの論理変更だけを含まなければならない（MUST）。
- commitは単独でrevertでき、buildとtestが成功する状態でなければならない（MUST）。
- refactorと動作変更は別commitにしなければならない（MUST）。
- 同じ作業で発生した軽微な修正を、意味のない独立commitにしてはならない（MUST NOT）。
- unrelatedな変更を同じcommitへ含めてはならない（MUST NOT）。
- AI agentはtaskまたはsubtaskの完了ごとにcommitし、明示的な依頼なしにwork in progressをcommitしてはならない（MUST NOT）。

## Gitmojiカテゴリー

projectで使用するgitmojiは、次のカテゴリーに分類する。commitのprefixには、後述するtype対応表のgitmojiを1つだけ使用しなければならない（MUST）。

| カテゴリー | 目的 | Gitmojiとtype |
| --- | --- | --- |
| 機能・修正 | 利用者向け機能、bug、性能、安全性 | `✨ feat`、`🐛 fix`、`⚡ perf`、`🔒 security` |
| コード品質 | 構造、書式、test | `♻️ refactor`、`🎨 style`、`✅ test` |
| ビルド・運用 | build、CI、保守 | `🏗️ build`、`👷 ci`、`🔧 chore` |
| ドキュメント・履歴 | documentation、revert | `📝 docs`、`⏪ revert` |

## Conventional Commitsのtype対応表

次のtypeとgitmojiの組み合わせだけを使用しなければならない（MUST）。

| type | Gitmoji | 用途 | SemVerへの標準的な影響 |
| --- | --- | --- | --- |
| `feat` | `✨` | backward compatibleな機能追加 | MINOR |
| `fix` | `🐛` | 不具合修正 | PATCH |
| `docs` | `📝` | documentationのみ | 原則なし |
| `style` | `🎨` | 動作に影響しないformat変更 | 原則なし |
| `refactor` | `♻️` | 機能とbug修正を伴わない再構成 | 原則なし |
| `perf` | `⚡` | backward compatibleな性能改善 | PATCH |
| `test` | `✅` | testの追加・修正 | 原則なし |
| `build` | `🏗️` | build system、dependency、package | 変更内容による |
| `ci` | `👷` | CI/CD設定とscript | 原則なし |
| `chore` | `🔧` | 製品codeを変更しない保守 | 原則なし |
| `revert` | `⏪` | 過去commitの取り消し | 取り消す変更による |
| `security` | `🔒` | backward compatibleな脆弱性修正 | PATCH |

`1.0.0`以降では、破壊的変更のversion影響はtypeにかかわらずMAJORとする。`0.y.z`期間では、破壊的変更でMINOR、backward compatibleな修正でPATCHを増加させ、破壊的変更をrelease noteへ明記しなければならない（MUST）。

## Gitタグ付与ルール

release versionはSemantic Versioning 2.0.0に従い、Git tagを`v<MAJOR>.<MINOR>.<PATCH>`形式で付与しなければならない（MUST）。

### バージョン決定

- backward incompatibleな変更ではMAJORを増加させなければならない（MUST）。
- backward compatibleな機能追加ではMINORを増加させなければならない（MUST）。
- backward compatibleなbugまたは脆弱性修正ではPATCHを増加させなければならない（MUST）。
- prereleaseには`v1.2.0-alpha.1`、`v1.2.0-beta.1`、`v1.2.0-rc.1`形式を使用しなければならない（MUST）。
- build metadataが必要な場合は`v1.2.3+build.5`形式を使用してもよい（MAY）。

### タグ作成

- tagは、CIとrelease確認が成功した`main`上のcommitだけへ付与しなければならない（MUST）。
- release tagはannotated tagとして作成しなければならない（MUST）。
- signing環境がある場合、signed tagを使用すべきである（SHOULD）。
- 公開済みtagを移動、上書き、再利用してはならない（MUST NOT）。誤りは新しいPATCH versionで修正しなければならない（MUST）。
- tag作成と同時にrelease noteを作成し、機能、修正、破壊的変更、移行手順を記載しなければならない（MUST）。

```bash
# release対象のmain commitへ移動する。
git switch main

# remoteのmainをfast-forwardで更新する。
git pull --ff-only origin main

# annotated release tagを作成する。
git tag -a v1.2.3 -m "v1.2.3"

# release tagをremoteへ送信する。
git push origin v1.2.3
```

期待値:

- `git pull --ff-only`がmerge commitを作らずに完了する。
- localの`refs/tags/v1.2.3`がrelease対象の`main` commitを指す。
- tag objectにrelease messageとtagger情報が記録される。
- remoteへ`v1.2.3`が新規tagとして送信される。

## References

- [GitHub flow](https://docs.github.com/en/get-started/using-github/github-flow)
- [Semantic Versioning 2.0.0](https://semver.org/)
- [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)
- [gitmoji](https://gitmoji.dev/)
- [RFC 8174: Ambiguity of Uppercase vs Lowercase in RFC 2119 Key Words](https://www.rfc-editor.org/info/rfc8174/)
