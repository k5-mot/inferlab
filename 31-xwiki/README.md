# 31-xwiki

XWikiとPostgreSQLを起動するWiki stack。

## 構成

- `xwiki`: XWiki 18.4.4 Intermediate Long Term Support（LTS）のPostgreSQL/Tomcat image。
- `xwiki-postgres`: XWikiの設定、page、attachment metadataを保持するPostgreSQL 18。
- `xwiki-data`: XWikiの永続directoryを保持するvolume。
- `xwiki-postgres-data`: PostgreSQL clusterを保持するvolume。

## 起動

```bash
# XWikiとPostgreSQLを起動する。
sudo docker compose --env-file .env --profile xwiki up -d

# 初回起動の状態を確認する。
sudo docker compose --env-file .env --profile xwiki ps

# XWikiのHTTP endpointを確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:33100/" >/dev/null
```

期待結果:

- `xwiki-postgres`と`xwiki`がhealthyになる。
- `http://${PUBLIC_HOST}:33100`にXWikiのDistribution Wizardまたは初期画面が表示される。
- container再作成後もXWikiとPostgreSQLのdataが保持される。

失敗条件:

- `xwiki-postgres`がhealthyにならない。
- `xwiki`のlogにdatabase接続失敗が記録される。
- 初回起動から15分経過してもXWikiがhealthyにならない。

## 初期設定

初回アクセス時はDistribution Wizardに従い、推奨flavorと必要なextensionを導入する。初期設定が完了するまで、通常のWiki pageは表示されない。Distribution Wizardがextensionを取得するため、初回設定時はinternet接続が必要になる。

```bash
# 初期設定中のXWiki logを確認する。
sudo docker compose --env-file .env --profile xwiki logs --follow xwiki
```

期待結果:

- Distribution Wizardが完了し、XWikiのhome pageが表示される。
- `xwiki` containerを再起動しても初期設定が保持される。

失敗条件:

- extension取得またはdatabase schema作成が失敗する。
- browserを再読み込みしてもDistribution Wizardが進行しない。

## References

- [XWiki Docker Compose required files](https://www.xwiki.org/xwiki/bin/view/documentation/xs/admin/installation/methods/install-xwiki-docker/docker-compose/required-files/)
- [Run XWiki with PostgreSQL on Tomcat](https://www.xwiki.org/xwiki/bin/view/documentation/xs/admin/installation/methods/install-xwiki-docker/docker-compose/run-xwiki-postgresql-tomcat/)
- [XWiki Docker images](https://github.com/xwiki/xwiki-docker)
