# Dify Air-gap Plugin調査

調査日: 2026-08-24

## 結論

Dify Community 1.16.1のair-gap運用ではMarketplaceを無効化し、署名付きplugin packageとPython依存wheelを接続可能な端末で事前取得する必要がある。model providerは公式`langgenius/openai_api_compatible` 0.0.64だけを採用し、内部LiteLLMへ接続する構成が最小である。

Dify向け外部Single Sign-Onは採用しない。Dify Enterpriseの公式機能表ではSAML、OIDC、OAuth2のSingle Sign-OnがEnterprise機能として案内されているため、Community構成はDify自身のemail/password認証へ限定する。

## 確認結果

- Dify 1.16.1の公式環境変数は既定でupdate確認、Marketplace、community telemetry、remote template取得、website readerを外部向けに有効化する。air-gap構成ではこれらを無効化し、appとpipelineのtemplate取得を`builtin`へ変更する必要がある。
- Dify Sandboxは既定でnetworkを有効化し、forward proxyを使用する。閉域構成ではnetworkを無効化できる。
- plugin daemonは`PIP_MIRROR_URL`を明示できる。自動mirror検出を無効化し、内部pypiserverだけを指定する必要がある。
- local `.difypkg`のupload自体はMarketplace接続を必要としないが、通常packageは初期化時にPython依存packageを解決する。依存wheelの内部mirrorが必要である。
- OpenAI-API-compatible 0.0.64はLLM、Rerank、Embedding、STT、TTSを1つのproviderで扱う。取得時のunique identifierは`langgenius/openai_api_compatible:0.0.64@e5a30fbe1e81f6ba97c27a77102f797a14953f50fddffecd09af11c9eda1ae7e`である。
- 2026-08-24に取得した署名付きpackageのSHA-256は`807252fac41666f135fa146001db41adde00eddd8e636154753f548c2daadb86`、内包`requirements.txt`のSHA-256は`893906c1f3b3e26afbf186fe68fb8ca517a2e4b72458947b10e6ec03c5d4f278`である。
- 固定requirementsはCPython 3.12 Linux x86_64向けに全wheelを解決できた。`gevent`、`greenlet`、`tiktoken`が新しいmanylinux tagを要求するため、`manylinux_2_28_x86_64`、`manylinux_2_24_x86_64`、`manylinux2014_x86_64`、`manylinux_2_17_x86_64`を併記する必要がある。

## 実装判断

plugin署名検証は無効化しない。Marketplaceから事前取得した公式packageをそのままlocal installし、Python依存だけを内部pypiserverから解決する。offline再packagingは署名と供給元検証の扱いが変わるため採用しない。

air-gapの強制境界はapplication設定だけでは完結しない。DifyのHTTP nodeや利用者が追加するpluginは任意URLへ接続できるため、Internet egressのdenyをnetwork境界で実施する必要がある。

## References

- [Dify Enterprise pricing and SSO features](https://dify.ai/pricing/dify-enterprise)
- [Dify 1.16.1 environment defaults](https://github.com/langgenius/dify/blob/1.16.1/docker/.env.example)
- [Dify plugin local file release and installation](https://docs.dify.ai/en/develop-plugin/publishing/marketplace-listing/release-by-file)
- [Dify Plugin Daemon environment configuration](https://github.com/langgenius/dify-plugin-daemon/blob/main/.env.example)
- [Dify official plugins repository](https://github.com/langgenius/dify-official-plugins/tree/main/models/openai_api_compatible)
- [Dify Marketplace OpenAI-API-compatible plugin](https://marketplace.dify.ai/plugin/langgenius/openai_api_compatible)
