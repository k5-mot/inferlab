# `owui` profile Specification

## Purpose

Docker Composeの`owui` profileが利用者と運用者へ提供する能力、公開境界、依存関係、正常性の判定を現行コードに基づいて定めます。

## Requirements

### Requirement: owui profileの提供範囲

`owui` profileは`open-webui`、`oikb`、`oikb-rustfs`、`oikb-rustfs-init`、`searxng`、`open-terminal`、`mcpo`、`libretranslate`を対象とし、AI chat、検索、翻訳、terminal、MCP、Knowledge Base同期を統合したWeb UIを提供するものとする（MUST）。

#### Scenario: profileを選択する

- **WHEN** 運用者が`owui` profileを選択してCompose設定を解決する
- **THEN** `open-webui`、`oikb`、`oikb-rustfs`、`oikb-rustfs-init`、`searxng`、`open-terminal`、`mcpo`、`libretranslate`がprofileの対象serviceとして含まれる
- **THEN** 長期稼働serviceは定義済みhealthcheckによって正常性を判定できる

### Requirement: owui profileの公開境界

`owui` profileは、Open WebUIをhostのTCP port `32000`、support serviceを`32001`から`32006`、LibreTranslateを`31300`で公開するものとする（MUST）。

#### Scenario: 利用者または依存serviceが接続する

- **WHEN** profileのserviceが起動してhealth判定に成功する
- **THEN** 定義された公開境界から提供機能へ接続できる
- **THEN** 未定義のhost portを追加で公開しない

### Requirement: owui profileの連携

`owui` profileは、LibreTranslateをOpenAPI toolとして登録し、mcpo経由でLLM Wikiのstdio MCPをOpenAPIとして利用可能にするものとする（MUST）。

#### Scenario: 連携先を利用する

- **WHEN** 必要なcredentialと依存serviceが利用可能である
- **THEN** profile固有の連携が定義された経路で成功する
- **THEN** credentialの実値をrepositoryへ保存しない

### Requirement: OIKB sourceの逐次同期

`owui` profileはOIKB内蔵schedulerが設定順にsourceを1件ずつ定時同期するものとする（MUST）。後続sourceは、OIKBの成功履歴とOpen WebUIのfile処理およびKnowledge link完了を確認するまで開始してはならない（MUST NOT）。

#### Scenario: 全sourceを1周期同期する

- **WHEN** 運用者がOIKBとOpen WebUIのAPI credentialおよびsource順を指定してOIKB daemonを起動する
- **THEN** 各sourceについて今回のOIKB同期が`success`となりhistoryへ保存されるまで待機する
- **THEN** 今回のfileがすべて`completed`となりKnowledge Baseへlinkされ、pending fileが0件になった後だけ次のsourceを開始する
- **THEN** 全sourceの完了後は設定した同期間隔を待って次の周期を開始する

#### Scenario: file登録の初回処理が失敗する

- **WHEN** Open WebUIへのfile登録が初回処理で失敗する
- **THEN** file登録の初回失敗では、作成済みの失敗fileを削除して同じfileを1回だけretryする
- **THEN** retryが成功するまで同じKnowledge Baseの次fileを開始しない

#### Scenario: 同期または登録が失敗する

- **WHEN** OIKBが成功以外で終了するか、Open WebUIのfile処理、link、件数照合、timeout判定またはfile retryが失敗する
- **THEN** 同じ周期の後続sourceを開始しない
- **THEN** 失敗したsourceと判定理由をlogへ記録する

### Requirement: Docling向け大容量PDF分割

`owui` profileは、設定したページ数を超えるPDFをOpen WebUI内で一時PDFへ分割し、各分割をDoclingへ逐次送信するものとする（MUST）。Open WebUIとOIKBでは元PDFを1つのfileとして扱い、分割後も元PDF上のページ順序を維持しなければならない（MUST）。

#### Scenario: 大容量PDFを取り込む

- **WHEN** 利用者またはOIKBが設定したページ数を超えるPDFをOpen WebUIへuploadする
- **THEN** Open WebUIは設定ページ数以下の一時PDFをDoclingへ1件ずつ送信する
- **THEN** 変換結果を元PDFのfile IDへ集約し、ページmetadataを元PDF上の順序で記録する
- **THEN** 一時PDFをOpen WebUIまたはOIKBのfileとして永続化しない

#### Scenario: 分割処理が失敗する

- **WHEN** PDFの読み込み、分割、またはいずれかのDocling変換が失敗する
- **THEN** 元PDFのfile処理を`failed`として扱う
- **THEN** 不完全な分割結果をKnowledge Baseへlinkしない

### Requirement: Open TerminalでのOffice作成

`owui` profileは、Open WebUIのchatでterminalを選んだuserが、通常modelまたはPi coding agentを使い、Open WebUI userごとのOS userとしてOpen Terminal上でOffice文書を作成できるものとする（MUST）。社内dataへのaccessはOpen WebUIの組み込みtoolだけで行い、Open WebUIのAPI keyとLiteLLM master keyをuserのprocessから読めてはならない（MUST NOT）。Open WebUIとOpen Terminalのsource codeを改修してはならない（MUST NOT）。

#### Scenario: 通常modelで社内dataから成果物を作る

- **WHEN** userが通常modelとterminalを選び、Knowledge、Notes、Memoryを根拠にした文書の作成を依頼する
- **THEN** modelはOpen WebUIの組み込みtoolでuserが読めるdataだけを取得し、terminal toolでOpen Terminal上に文書を作る
- **THEN** modelはuserのhomeの`~/AGENTS.md`と`~/.agents/skills`を指示として受け取る

#### Scenario: RAGの回答をPiへ渡す

- **WHEN** userが同じchatで、通常modelにKnowledgeを付けて質問した後、modelをPiへ切り替えて依頼する
- **THEN** Piは前の回答を会話履歴として受け取り、Open WebUIのAPIを呼ばずに成果物を作る

#### Scenario: PiがLiteLLMを呼ぶ

- **WHEN** Piが`llm-broker`経由でLiteLLMを呼ぶ
- **THEN** `llm-broker`はchat completionsとmodel一覧だけをmaster key付きで中継し、それ以外は403を返す
- **THEN** `llm-broker`は接続元socketの所有uidで判定したOS user名をLangfuseのtrace userとして付ける

#### Scenario: Open Terminalを再作成する

- **WHEN** 運用者が`open-terminal`を再作成する
- **THEN** userごとのhome (Pi session、成果物) は`open-terminal-homes` volumeに残り、既存homeにも`~/AGENTS.md`と`~/.agents/skills`のlinkが作られる
- **THEN** `open-terminal`には`/var/run/docker.sock`がmountされない
