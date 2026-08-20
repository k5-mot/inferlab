# Keycloak HTTPS Certificates

Zulip の OIDC 連携は HTTPS issuer を使用するため、このディレクトリの自己署名証明書を `keycloak-https` で使用します。

`../generate-certs.sh` で `keycloak.crt` と `keycloak.key` を生成してください。秘密鍵をリポジトリへ保存しないため、生成物は `.gitignore` しています。

この証明書はローカル検証用です。ブラウザの警告を消すには、利用端末側で `keycloak.crt` を信頼済み証明書として登録するか、実運用向けの証明書へ差し替えてください。
