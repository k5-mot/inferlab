# Homepage icon labels

Homepage の `homepage.icon` ラベルを、外部アイコン指定とローカルアイコン指定で切り替えるためのラベルファイルです。

- `false/`: 変更前と同じ外部アイコン指定を使います。
- `true/`: `00-common/homepage/icons/` のローカル汎用 SVG を使います。

Docker Compose では `label_file` のパスに `${AIRGAP:-false}` を使っています。`.env` で `AIRGAP=true` を指定した場合だけ `true/` のラベルファイルが読み込まれ、未設定または `AIRGAP=false` の場合は `false/` が読み込まれます。
