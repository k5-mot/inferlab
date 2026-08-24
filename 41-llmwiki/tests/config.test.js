import assert from 'node:assert/strict';
import test from 'node:test';
import {buildProviderEnvironment, parseConfig} from '../dist/config.js';

/**
 * testごとに変更できる最小の有効設定を生成する。
 * @returns 有効な未変換設定object。
 */
function baseConfig() {
  return {
    version: 1,
    project: {root: '/data/llmwiki'},
    scheduler: {timezone: 'Asia/Tokyo'},
    defaults: {
      ingest: {enabled: false, schedule: '0 * * * *', timeout_seconds: 600},
    },
    sources: [],
    compile: {
      enabled: false,
      schedule: '*/30 * * * *',
      on_ingest: false,
      concurrency: 5,
      review: false,
      timeout_seconds: 3600,
    },
    provider: {
      kind: 'openai',
      model: 'openai/gpt-oss:20b',
      base_url: 'http://litellm:4000/v1',
      credential_env: 'LITELLM_MASTER_KEY',
      embedding: {
        kind: 'openai',
        model: 'cl-nagoya/ruri-v3:310m',
        base_url: 'http://litellm:4000/v1',
        credential_env: 'LITELLM_MASTER_KEY',
        batch_size: 2,
        strict: false,
      },
    },
    output: {language: 'Japanese'},
    viewer: {
      internal_port: 54321,
      public_host: '0.0.0.0',
      public_port: 8080,
      startup_timeout_seconds: 30,
    },
    validation: {enabled: false},
  };
}

test('source共通既定値へsource別overrideを適用する', () => {
  const value = baseConfig();
  value.sources = [{
    id: 'handbook',
    input: 'https://example.test/handbook',
    ingest: {enabled: true, schedule: '*/5 * * * *'},
  }];

  const config = parseConfig(value);

  assert.deepEqual(config.sources[0].ingest, {
    enabled: true,
    schedule: '*/5 * * * *',
    timeoutSeconds: 600,
  });
});

test('初期MVPでvalidation有効化を拒否する', () => {
  const value = baseConfig();
  value.validation.enabled = true;

  assert.throws(() => parseConfig(value));
});

test('定期compile有効時は参照credentialを必須にする', () => {
  const value = baseConfig();
  value.compile.enabled = true;
  const config = parseConfig(value);

  assert.throws(
    () => buildProviderEnvironment(config, {}),
    /LITELLM_MASTER_KEY/,
  );
});

test('one-shot compileはschedule無効時もcredentialを必須にする', () => {
  const config = parseConfig(baseConfig());

  assert.throws(
    () => buildProviderEnvironment(config, {}, true),
    /LITELLM_MASTER_KEY/,
  );
});

test('viewerのみの起動ではprovider credentialを要求しない', () => {
  const config = parseConfig(baseConfig());

  const environment = buildProviderEnvironment(config, {});

  assert.equal(environment.OPENAI_API_KEY, undefined);
  assert.equal(environment.LLMWIKI_PROVIDER, 'openai');
  assert.equal(environment.LLMWIKI_EMBEDDING_MODEL, 'cl-nagoya/ruri-v3:310m');
  assert.equal(environment.LLMWIKI_EMBED_BATCH_SIZE, '2');
});
