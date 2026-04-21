# brainbox

このリポジトリの設計・構成の正本 (SSOT) は [DESIGN.md](./DESIGN.md) です。
詳細仕様は DESIGN.md を参照してください。

## 起動

```bash
COMPOSE_PARALLEL_LIMIT=1 docker compose pull --policy missing --quiet
docker compose up -d
```

必要に応じて profile を有効化:

```bash
docker compose --profile inference up -d
docker compose --profile media up -d
docker compose --profile inference --profile media up -d
```

## 検証

```bash
docker compose config --quiet
docker compose --profile inference --profile media config --quiet
docker compose config --services
docker compose --profile inference --profile media config --services
```
