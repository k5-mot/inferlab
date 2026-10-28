# OIKB2

OIKB2は、OIKB 0.6.0のfile uploadを1件ずつ完了させるcustom imageである。ルートのComposeは`20-owui/oikb2`をbuild contextとして使用する。

OIKB 0.6.0の既定`concurrency=1`はupload requestを順番に送るが、標準clientは変換・Embedding・Knowledge Base（KB）登録の完了を待たない。daemonのKB単位lockは同一KBの重複処理を防ぐが、異なるKBの並行処理は防がない。本custom imageはその不足分を補う。CLIの`--concurrency`を1より大きくするとfile単位の逐次性は保証されないため、逐次同期では既定値を使う。

各fileでは、次の処理を完了してから次のfileへ進む。

1. Open WebUIへfileをuploadする。
2. background処理を無効にしたrequest内でMarkdown変換とvector作成を待つ。
3. file statusが`completed`であることを確認する。
4. file IDが対象Knowledge Baseのfile一覧に現れることを確認する。

内蔵scheduler patchは、`oikb.yaml`をKB単位にまとめ、設定順に1KBずつ同期する。同じKBの複数sourceはOIKB 0.6.0標準の一括manifest処理を使用する。最後のfileの登録確認後に現在のKBが終了し、成功した場合だけ次のKBを開始する。手動triggerもKB間で重ならない。全KBの完了後は、両sourceに設定した共通の6時間を待って次周期を開始する。

同じpatchは、OIKBのdry-run responseへ`added`と`modified`のfile詳細を追加し、dry-run終了後のsource状態を`idle`へ戻す。これにより`oikb_sync.py trigger --dry-run`が未同期fileをlogへ表示した後も、通常のtriggerを開始できる。

## ビルド

repository rootから実行する。

```bash
# OIKB2 imageをbuildする。
sudo docker compose --env-file .env --profile owui --profile nextcloud build oikb
```

期待結果:

- base imageのOIKB 0.6.0へ3つのpatchが適用される。
- `patch-openwebui-sequential-registration.py`がerrorなく終了する。
- dry-run responseが未同期fileのactionとpathを返す。

失敗条件:

- OIKB 0.6.0のsourceとpatch対象が一致せず、buildが終了code 1になる。
- base imageまたはPython dependencyを取得できない。

## 起動

```bash
# OIKB2 imageでOIKB serviceだけを再作成する。
sudo docker compose --env-file .env \
  --profile owui --profile nextcloud up -d --no-deps oikb
```

期待結果:

- OIKBがhealthyになる。
- 内蔵schedulerが起動し、設定順にsourceの同期を開始する。

失敗条件:

- Open WebUI API keyまたはKnowledge Base IDが未設定で同期に失敗する。
- OIKB health endpointが応答しない。

## 逐次同期の確認

別terminalでOIKB2のlogを追跡する。

```bash
# 処理開始fileとKnowledge登録完了fileをリアルタイム表示する。
sudo docker compose --env-file .env \
  --profile owui --profile nextcloud logs -f oikb
```

処理中は`OIKB2 processing file`、登録確認後は`OIKB2 registered file`としてKnowledge Base ID、file名、file IDを出力する。開始logの後に登録完了logがまだないfileが、現在処理中のfileである。

期待結果:

- 同時に処理中となるfileは1件だけになる。
- OIKB2のDocker logへ処理中のKnowledge Base IDとfile名が表示される。
- OIKB WebUIの対象source行直下へ、処理中fileのbasenameが表示される。
- file登録に失敗した場合は、初回のfileを削除して同じfileを1回retryする。
- 削除に失敗した場合は重複uploadを避けるためretryせず失敗にする。
- fileごとに`completed`とKnowledge Baseへのlinkを確認してから次のfileへ進む。
- 現在のKnowledge Baseの最後のfileを確認してから、次のKnowledge Baseを開始する。

失敗条件:

- file statusが`failed`になる。
- fileがKnowledge Baseのfile一覧へ現れずtimeoutになる。
- retry後も同じfileの登録が失敗する。
- 失敗後に同じKnowledge Baseの次fileまたは次のKnowledge Baseが開始される。

手動で1周期だけ確認する場合は、OIKB daemonを停止してから`python3 scripts/oikb/oikb_sync.py trigger`を実行する。daemonと保守CLIを同時実行すると同期が重複するため、併用してはならない（MUST NOT）。

## WebUIで処理中fileを確認

OIKB WebUIを`http://${PUBLIC_HOST}:32001/`で開く。通常sync中は、対象source行の直下へ現在登録しているfileのbasenameを表示する。表示は既存のhealth checkを10秒間隔で更新するため、処理開始と完了から画面反映まで最大10秒かかる。

file名はHTML escapeして表示する。directory pathは公開せず、dry-run、idle、成功、失敗、timeout後はfile名を表示しない。`/health`は認証なしで同じ値を返すため、OIKBの公開範囲は信頼済みnetworkへ限定しなければならない（MUST）。

## Rollback

以前のOIKB imageを使う場合は、Composeの`oikb.image`と`oikb.build.context`を以前の組み合わせ（`0.4.0-patch2`、`./oikb`）へ戻してから次を実行する。新しいimage tagのまま旧imageへ切り替えてはならない（MUST NOT）。

```bash
# Composeで指定した旧OIKB imageをbuildする。
sudo docker compose --env-file .env \
  --profile owui --profile nextcloud build oikb

# build済みの旧OIKB imageでserviceを再作成する。
sudo docker compose --env-file .env \
  --profile owui --profile nextcloud up -d --no-deps --no-build oikb
```

期待結果:

- `20-owui/oikb`のimageへ戻る。
- Open WebUI内のfileとKnowledge Baseは削除されない。

失敗条件:

- 既定OIKB imageのbuildまたはservice再作成に失敗する。

## References

- [OIKB v0.6.0 client](https://github.com/open-webui/oikb/blob/v0.6.0/src/oikb/client.py)
- [OIKB v0.6.0 daemon](https://github.com/open-webui/oikb/blob/v0.6.0/src/oikb/daemon.py)
- [Open WebUI v0.12.4 file API](https://github.com/open-webui/open-webui/blob/v0.12.4/backend/open_webui/routers/files.py)
