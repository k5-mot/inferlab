# 36-sigstore

GitLab CIから[cosign](https://github.com/sigstore/cosign)でkeyless署名するための、自前ホストの[Sigstore](https://www.sigstore.dev/)基盤を提供するprofile。

keyless署名とは、長期保管する署名鍵を使わず、CI jobのOIDC ID tokenで本人性を証明し、短命な証明書で署名する方式である。

## MVPの段階

本stackは、初期MVPと最終MVPの2段階で構成する。

| 段階 | Compose file | 構成 | 検証できること |
| --- | --- | --- | --- |
| 初期MVP | `docker-compose.yml` | Fulcio、Rekor v2、Timestamp Authority、GitLab OIDC | 署名、identity、改ざん、Rekor記録、署名時刻 |
| 最終MVP | `docker-compose.yml` + `docker-compose.final.yml` | 初期MVP + Certificate Transparency log | 初期MVPの内容 + 証明書のCT記録 (SCT) |

`docker-compose.final.yml`は単独で使用しないoverride fileである。初期MVPのserviceへCT logを追加し、Fulcioとtrusted rootの設定を置き換える。

### 初期MVPにTimestamp Authorityを含める理由

初期MVPの本来の範囲はFulcio、Rekor、GitLab OIDCである。ただし、[Rekor v2](https://github.com/sigstore/rekor-tiles)はRekor v1と異なりentryの記録時刻 (integrated time) を返さない。そのため、cosign v3はTimestamp Authority (TSA) がない構成での署名を次のerrorで拒否する。

```text
a timestamp authority must be provided to request a short-lived certificate that will be logged to Rekor
```

このため、TSAはRekor v2を使うための必須依存として初期MVPに含める。

### 初期MVPで省略する検証

初期MVPのFulcioはCT logへ証明書を記録しないため、証明書にSCT (Signed Certificate Timestamp) が付与されない。初期MVPでの検証には`--insecure-ignore-sct`が必要である。最終MVPではこのflagを外し、SCTも検証する。

## 構成

| service | 段階 | port | 役割 |
| --- | --- | --- | --- |
| `sigstore-init` | 共通 | - | 鍵とCA証明書を初回だけ生成し、volume所有者を調整する |
| `fulcio` | 共通 | `33600` | GitLab CIのID tokenを検証し、code signing証明書を発行する |
| `rekor` | 共通 | `33601` | 署名をtransparency logへ記録する (Rekor v2、POSIX storage) |
| `timestamp-authority` | 共通 | `33602` | RFC 3161 timestampを発行する |
| `sigstore-trusted-root` | 共通 | - | cosign用`trusted_root.json`を生成する |
| `sigstore-signing-config` | 共通 | - | cosign用`signing_config.json`を生成する |
| `sigstore-dist` | 共通 | `33603` | trust materialとlog tileを静的配信する |
| `ctlog` | 最終MVP | - | Fulcio証明書をCT logへ記録する (TesseraCT) |

`sigstore-dist`は次のpathを配信する。

- `/trust/`: `trusted_root.json`、`signing_config.json`、各公開鍵と証明書chain。
- `/rekor/`: Rekor v2のcheckpointとtile。
- `/ct/`: CT logのcheckpointとtile (最終MVPのみ)。

鍵はnamed volumeに保存する。volumeを削除すると鍵とtrust materialが変わり、過去の署名を検証できなくなる。

## 前提

- `.env`に`STACK_NAME`と`PUBLIC_HOST`が設定されている。
- [34-gitlab](../34-gitlab/README.md)のGitLabが`http://${PUBLIC_HOST}:33400`で起動し、GitLab Runnerが登録済みである。
- Fulcioとjob containerから`http://${PUBLIC_HOST}:33400`へ到達できる。

任意で次の環境変数を`.env`へ設定する。

| 変数 | 既定値 | 用途 |
| --- | --- | --- |
| `FULCIO_CA_PASSWORD` | `pw-fulcio-ca-password-change-me` | Fulcio CA秘密鍵の暗号化password |
| `TSA_SIGNER_PASSWORD` | `pw-tsa-signer-password-change-me` | TSA署名鍵の暗号化password |
| `SIGSTORE_ORGANIZATION` | `InferLab` | 証明書のorganizationとsigning configのoperator |
| `SIGSTORE_CONTACT` | `admin@example.com` | Fulcio issuer設定の連絡先 |
| `SIGSTORE_TRUST_START_TIME` | `2026-01-01T00:00:00Z` | trusted rootの有効開始時刻 |

passwordは鍵の初回生成前に設定しなければならない (MUST)。生成後に変更すると、Fulcioとtimestamp-authorityが鍵を復号できなくなる。

## 初期MVPの起動手順

```bash
# GitLab、Keycloak、初期MVPのSigstore一式を起動する。
sudo docker compose --profile sigstore --profile gitlab --profile keycloak up -d --remove-orphans

# trust materialが配信されていることを確認する。
curl -fsS "http://${PUBLIC_HOST}:33603/trust/signing_config.json"
```

期待結果:

- `sigstore-init`、`sigstore-trusted-root`、`sigstore-signing-config`が終了code `0`で終了する。
- `fulcio`、`rekor`、`timestamp-authority`が`Up`になり、`sigstore-dist`が`healthy`になる。
- `signing_config.json`にFulcio、Rekor (API version 2)、TSAのURLが含まれる。

失敗条件:

- `sigstore-init`が`0`以外で終了する。
- `sigstore-dist`が`403`を返す、または`healthy`にならない。
- Fulcioのlogに`error creating provider for issuer URL`が出続ける。GitLab起動前のlogは、GitLab起動後に署名要求が成功すれば問題ない。

## 最終MVPの起動手順

```bash
# 最終MVPのoverrideを重ねて、CT logを追加する。
sudo docker compose -f docker-compose.yml -f 36-sigstore/docker-compose.final.yml --profile sigstore up -d --force-recreate

# trusted rootへCT logが追加されたことを確認する。
curl -fsS "http://${PUBLIC_HOST}:33603/trust/trusted_root.json" | grep -c '"ctlogs"'
```

期待結果:

- `ctlog`が`Up`になり、logに`CT HTTP Server Starting`が出力される。
- `trusted_root.json`に`ctlogs`と`timestampAuthorities`が含まれる。

失敗条件:

- `ctlog`が再起動を繰り返す。
- `trusted_root.json`に`ctlogs`が含まれない。

### 最終MVPから初期MVPへ戻す手順

```bash
# overrideなしで再作成し、FulcioのCT log連携を外す。
sudo docker compose --profile sigstore up -d --force-recreate --remove-orphans
```

期待結果:

- `ctlog`が削除され、`trusted_root.json`から`ctlogs`が外れる。

CT log volumeは削除しないため、再度最終MVPへ切り替えると同じCT log鍵を使用する。

## GitLab CIでの署名と検証

[examples/gitlab-ci.yml](examples/gitlab-ci.yml)を対象projectの`.gitlab-ci.yml`として配置する。

- `id_tokens`で`aud: sigstore`のID tokenを発行し、cosignへ渡す。
- 通常のcosign imageにはshellがないため、jobではshell付きの`cosign:v3.1.4-dev` imageを使用する。
- 初期MVPでは`COSIGN_VERIFY_EXTRA_FLAGS: "--insecure-ignore-sct"`を使用する。
- 最終MVPでは`COSIGN_VERIFY_EXTRA_FLAGS: ""`へ変更する。

証明書のidentity (SAN) は次の形式になる。

```text
http://<GitLab host>:<port>/<group>/<project>//.gitlab-ci.yml@refs/heads/<branch>
```

GitLab CI以外から検証する場合は、`trusted_root.json`を取得してから実行する。

```bash
# 検証に使用するtrusted rootを取得する。
curl -fsS -o trusted_root.json "http://${PUBLIC_HOST}:33603/trust/trusted_root.json"

# 署名者のpipeline定義とissuerを固定して検証する。
cosign verify-blob \
  --trusted-root trusted_root.json \
  --bundle artifact.sigstore.json \
  --certificate-identity "http://${PUBLIC_HOST}:33400/root/sigstore-verify//.gitlab-ci.yml@refs/heads/main" \
  --certificate-oidc-issuer "http://${PUBLIC_HOST}:33400" \
  artifact.txt
```

期待結果:

- `Verified OK`が出力される。

失敗条件:

- identityまたはissuerが一致しない場合、`no matching CertificateIdentity found`で失敗する。
- artifactが改ざんされている場合、`invalid signature`で失敗する。
- 最終MVPでSCTを検証できない場合、`unable to meet threshold of 1`で失敗する。

## 動作確認結果

2026-11-25に、GitLab CE 19.6.1とGitLab Runner 19.6.0で次を確認した。

| 段階 | 確認内容 | 結果 |
| --- | --- | --- |
| 初期MVP | GitLab CI jobで`sign-blob`と`verify-blob --insecure-ignore-sct` | 成功 |
| 最終MVP | GitLab CI jobで`sign-blob`と`verify-blob` (SCT検証あり) | 成功 |
| 最終MVP | 異なるidentityでの検証 | 期待どおり失敗 |
| 最終MVP | 改ざんしたartifactの検証 | 期待どおり失敗 |

## 設計上の注意

- Rekorの`--hostname`は`${PUBLIC_HOST}` (portなし) にしなければならない (MUST)。cosign (sigstore-go) はtrusted rootの`baseUrl`からportを除いたhost名をcheckpoint originとして使用する。
- TesseraCTは`host:port`形式のoriginを受け付けないため、CT logのoriginは`ctlog`とし、Fulcioへ`--ct-log-origin=ctlog`を指定する。
- Fulcioの設定は`configs.content`で注入するため、Fulcio containerへ`read_only`を指定できない。
- Fulcio、Rekor、TSA、CT logのimageはdistrolessでshellとHTTP clientを持たないため、container内healthcheckを定義しない。
- timestamp-authorityは`--disable-ntp-monitoring`で起動する。時刻の正確性はhostの時刻同期に依存する。

## References

- [sigstore/rekor-tiles](https://github.com/sigstore/rekor-tiles)
- [sigstore/fulcio](https://github.com/sigstore/fulcio)
- [Fulcio setup](https://github.com/sigstore/fulcio/blob/main/docs/setup.md)
- [sigstore/timestamp-authority](https://github.com/sigstore/timestamp-authority)
- [transparency-dev/tesseract](https://github.com/transparency-dev/tesseract)
- [cosign trusted-root create](https://github.com/sigstore/cosign/blob/main/doc/cosign_trusted-root_create.md)
- [cosign signing-config create](https://github.com/sigstore/cosign/blob/main/doc/cosign_signing-config_create.md)
- [sigstore-go checkpoint verification](https://github.com/sigstore/sigstore-go/blob/main/pkg/verify/tlog.go)
- [GitLab OpenID Connect (OIDC) Authentication Using ID Tokens](https://docs.gitlab.com/ci/secrets/id_token_authentication/)
