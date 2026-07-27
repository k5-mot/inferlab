# Homepage icon labels

Homepage の `homepage.icon` ラベルを管理するためのラベルファイルです。

- Dashboard Icons に正式な製品アイコンがあるサービスは、`false/` と `true/` の両方で `00-common/homepage/icons/` のローカル PNG を使います。
- Dashboard Icons に該当アイコンが見つからないサービスは、既存の外部アイコン指定またはローカル SVG フォールバックを使います。

Docker Compose では互換性のため、`label_file` のパスに `${AIRGAP:-false}` を使っています。
