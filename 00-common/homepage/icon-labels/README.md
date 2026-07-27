# Homepage icon labels

Homepage の `homepage.icon` ラベルを管理するためのラベルファイルです。

- サービスのアイコンは、`false/` と `true/` の両方で `00-common/homepage/icons/` のローカル PNG を使います。

Docker Compose では互換性のため、`label_file` のパスに `${AIRGAP:-false}` を使っています。
