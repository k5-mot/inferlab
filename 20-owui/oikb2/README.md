# OIKB2

OIKB2は、OIKB 0.4.0のfile uploadを1件ずつ完了させるcustom imageである。ルートのComposeは`20-owui/oikb2`をbuild contextとして使用する。

各fileでは、次の処理を完了してから次のfileへ進む。

1. Open WebUIへfileをuploadする。
2. background処理を無効にしたrequest内でMarkdown変換とvector作成を待つ。
3. file statusが`completed`であることを確認する。
4. file IDが対象Knowledge Baseのfile一覧に現れることを確認する。

内蔵scheduler patchは、`oikb.yaml`のsourceを設定順に1件ずつ同期する。最後のfileの登録確認後に現在のsourceが終了し、成功した場合だけ次のsourceを開始する。全sourceの完了後は、両sourceに設定した共通の6時間を待って次周期を開始する。

同じpatchは、OIKBのdry-run responseへ`added`と`modified`のfile詳細を追加し、dry-run終了後のsource状態を`idle`へ戻す。これにより`oikb_sync.py trigger --dry-run`が未同期fileをlogへ表示した後も、通常のtriggerを開始できる。

## ビルド

repository rootから実行する。

```bash
# OIKB2 imageをbuildする。
sudo docker compose --env-file .env --profile owui --profile nextcloud build oikb
```

期待結果:

- base imageのOIKB 0.4.0へ3つのpatchが適用される。
- `patch-openwebui-sequential-registration.py`がerrorなく終了する。
- dry-run responseが未同期fileのactionとpathを返す。

失敗条件:

- OIKB 0.4.0のsourceとpatch対象が一致せず、buildが終了code 1になる。
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

```bash
# 既存OIKBのContainerfileを同じlocal tagへbuildする。
sudo docker build \
  -t ghcr.io/open-webui/oikb:0.4.0-patch2 \
  -f 20-owui/oikb/Containerfile \
  20-owui/oikb

# build済みの既存OIKB imageでserviceを再作成する。
sudo docker compose --env-file .env \
  --profile owui --profile nextcloud up -d --no-deps --no-build oikb
```

期待結果:

- `20-owui/oikb`のimageへ戻る。
- Open WebUI内のfileとKnowledge Baseは削除されない。

失敗条件:

- 既定OIKB imageのbuildまたはservice再作成に失敗する。

## References

- [OIKB v0.4.0 client](https://github.com/open-webui/oikb/blob/f99d2e66e7c0a24e5fe336a0242d5b334f979af6/src/oikb/client.py)
- [Open WebUI v0.11.1 file API](https://github.com/open-webui/open-webui/blob/d3e8bf3405e848cfba377814d0aa7ba7290e414d/backend/open_webui/routers/files.py)
- [Open WebUI v0.11.1 Knowledge API](https://github.com/open-webui/open-webui/blob/d3e8bf3405e848cfba377814d0aa7ba7290e414d/backend/open_webui/routers/knowledge.py)
