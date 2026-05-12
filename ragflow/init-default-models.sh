#!/bin/sh
set -eu

db="${RAGFLOW_MYSQL_DBNAME:-rag_flow}"
export MYSQL_PWD="${RAGFLOW_MYSQL_PASSWORD:-infini_rag_flow}"

echo "Waiting for RAGFlow tenant tables..."
until mysql -h ragflow-mysql -uroot "$db" -Nse "SHOW TABLES LIKE 'tenant';" | grep -q '^tenant$'; do
  sleep 3
done

until mysql -h ragflow-mysql -uroot "$db" -Nse "SHOW TABLES LIKE 'tenant_llm';" | grep -q '^tenant_llm$'; do
  sleep 3
done

until [ "$(mysql -h ragflow-mysql -uroot "$db" -Nse "SELECT COUNT(*) FROM tenant;")" -gt 0 ]; do
  sleep 3
done

mysql -h ragflow-mysql -uroot "$db" <<SQL
SET @chat_model = '${RAGFLOW_CHAT_MODEL:-gemma4:31b}';
SET @embedding_model = '${RAGFLOW_EMBEDDING_MODEL:-ruri-v3:310m}';
SET @rerank_model = '${RAGFLOW_RERANK_MODEL:-ruri-v3-reranker:310m}';
SET @rerank_factory = '${RAGFLOW_RERANK_FACTORY:-OpenAI-API-Compatible}';
SET @openai_base_url = '${RAGFLOW_OPENAI_BASE_URL:-http://litellm:4000/v1}';
SET @openai_api_key = '${RAGFLOW_OPENAI_API_KEY:-sk-litellm-master-key}';
SET @vision_model = '${RAGFLOW_VISION_MODEL:-gemma3:31b}';
SET @vision_base_url = '${RAGFLOW_VISION_BASE_URL:-http://litellm:4000/v1}';
SET @vision_api_key = '${RAGFLOW_VISION_API_KEY:-sk-litellm-master-key}';
SET @vision_max_tokens = ${RAGFLOW_VISION_MAX_TOKENS:-128000};
SET @tts_model = '${RAGFLOW_TTS_MODEL:-tts-1}';
SET @tts_base_url = '${RAGFLOW_TTS_BASE_URL:-http://openai-edge-tts:5050/v1}';
SET @tts_api_key = '${RAGFLOW_TTS_API_KEY:-openai-edge-tts-api-secret-key}';
SET @tts_max_tokens = ${RAGFLOW_TTS_MAX_TOKENS:-4096};
SET @now_ms = UNIX_TIMESTAMP(NOW(3)) * 1000;

INSERT INTO tenant_llm (
  tenant_id,
  llm_factory,
  model_type,
  llm_name,
  api_key,
  api_base,
  max_tokens,
  used_tokens,
  status,
  create_time,
  update_time
)
SELECT
  id,
  'OpenAI',
  'chat',
  @chat_model,
  @openai_api_key,
  @openai_base_url,
  128000,
  0,
  '1',
  @now_ms,
  @now_ms
FROM tenant
ON DUPLICATE KEY UPDATE
  model_type = VALUES(model_type),
  api_key = VALUES(api_key),
  api_base = VALUES(api_base),
  max_tokens = VALUES(max_tokens),
  status = VALUES(status),
  update_time = VALUES(update_time);

INSERT INTO tenant_llm (
  tenant_id,
  llm_factory,
  model_type,
  llm_name,
  api_key,
  api_base,
  max_tokens,
  used_tokens,
  status,
  create_time,
  update_time
)
SELECT
  id,
  'OpenAI',
  'embedding',
  @embedding_model,
  @openai_api_key,
  @openai_base_url,
  8191,
  0,
  '1',
  @now_ms,
  @now_ms
FROM tenant
ON DUPLICATE KEY UPDATE
  model_type = VALUES(model_type),
  api_key = VALUES(api_key),
  api_base = VALUES(api_base),
  max_tokens = VALUES(max_tokens),
  status = VALUES(status),
  update_time = VALUES(update_time);

INSERT INTO tenant_llm (
  tenant_id,
  llm_factory,
  model_type,
  llm_name,
  api_key,
  api_base,
  max_tokens,
  used_tokens,
  status,
  create_time,
  update_time
)
SELECT
  id,
  @rerank_factory,
  'rerank',
  @rerank_model,
  @openai_api_key,
  @openai_base_url,
  8191,
  0,
  '1',
  @now_ms,
  @now_ms
FROM tenant
ON DUPLICATE KEY UPDATE
  model_type = VALUES(model_type),
  api_key = VALUES(api_key),
  api_base = VALUES(api_base),
  max_tokens = VALUES(max_tokens),
  status = VALUES(status),
  update_time = VALUES(update_time);

INSERT INTO tenant_llm (
  tenant_id,
  llm_factory,
  model_type,
  llm_name,
  api_key,
  api_base,
  max_tokens,
  used_tokens,
  status,
  create_time,
  update_time
)
SELECT
  id,
  'OpenAI',
  'image2text',
  @vision_model,
  @vision_api_key,
  @vision_base_url,
  @vision_max_tokens,
  0,
  '1',
  @now_ms,
  @now_ms
FROM tenant
ON DUPLICATE KEY UPDATE
  model_type = VALUES(model_type),
  api_key = VALUES(api_key),
  api_base = VALUES(api_base),
  max_tokens = VALUES(max_tokens),
  status = VALUES(status),
  update_time = VALUES(update_time);

INSERT INTO tenant_llm (
  tenant_id,
  llm_factory,
  model_type,
  llm_name,
  api_key,
  api_base,
  max_tokens,
  used_tokens,
  status,
  create_time,
  update_time
)
SELECT
  id,
  'OpenAI',
  'tts',
  @tts_model,
  @tts_api_key,
  @tts_base_url,
  @tts_max_tokens,
  0,
  '1',
  @now_ms,
  @now_ms
FROM tenant
ON DUPLICATE KEY UPDATE
  model_type = VALUES(model_type),
  api_key = VALUES(api_key),
  api_base = VALUES(api_base),
  max_tokens = VALUES(max_tokens),
  status = VALUES(status),
  update_time = VALUES(update_time);

UPDATE tenant AS t
JOIN tenant_llm AS v
  ON v.tenant_id = t.id
  AND v.llm_factory = 'OpenAI'
  AND v.model_type = 'image2text'
  AND v.llm_name = @vision_model
SET
  t.img2txt_id = CONCAT(@vision_model, '@OpenAI'),
  t.tenant_img2txt_id = v.id,
  t.update_time = @now_ms;

UPDATE tenant AS t
JOIN tenant_llm AS m
  ON m.tenant_id = t.id
  AND m.llm_factory = 'OpenAI'
  AND m.model_type = 'tts'
  AND m.llm_name = @tts_model
SET
  t.tts_id = CONCAT(@tts_model, '@OpenAI'),
  t.tenant_tts_id = m.id,
  t.update_time = @now_ms;

UPDATE tenant AS t
JOIN tenant_llm AS m
  ON m.tenant_id = t.id
  AND m.llm_factory = 'OpenAI'
  AND m.model_type = 'chat'
  AND m.llm_name = @chat_model
SET
  t.llm_id = CONCAT(@chat_model, '@OpenAI'),
  t.tenant_llm_id = m.id,
  t.update_time = @now_ms;

UPDATE tenant AS t
JOIN tenant_llm AS m
  ON m.tenant_id = t.id
  AND m.llm_factory = 'OpenAI'
  AND m.model_type = 'embedding'
  AND m.llm_name = @embedding_model
SET
  t.embd_id = CONCAT(@embedding_model, '@OpenAI'),
  t.tenant_embd_id = m.id,
  t.update_time = @now_ms;

UPDATE tenant AS t
JOIN tenant_llm AS m
  ON m.tenant_id = t.id
  AND m.llm_factory = @rerank_factory
  AND m.model_type = 'rerank'
  AND m.llm_name = @rerank_model
SET
  t.rerank_id = CONCAT(@rerank_model, '@', @rerank_factory),
  t.tenant_rerank_id = m.id,
  t.update_time = @now_ms;
SQL

echo "RAGFlow default models initialized."
