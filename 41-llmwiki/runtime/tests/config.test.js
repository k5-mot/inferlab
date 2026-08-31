import assert from 'node:assert/strict';
import test from 'node:test';
import {buildProviderEnvironment, parseConfig} from '../dist/config.js';

/**
 * Runtime test用の最小有効設定を生成する。
 * @returns Runtime設定を含む未変換設定object。
 */
function baseConfig() {
  return {
    version: 1,
    project: {root: '/data/llmwiki'},
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
    runtime: {
      viewer: {
        internal_port: 54321,
        public_host: '0.0.0.0',
        public_port: 8080,
        startup_timeout_seconds: 30,
        reload_poll_seconds: 2,
      },
    },
    ingester: {},
  };
}

test('Runtime設定だけを正規化する', () => {
  const config = parseConfig(baseConfig());

  assert.equal(config.projectRoot, '/data/llmwiki');
  assert.equal(config.viewer.publicPort, 8080);
  assert.equal('sources' in config, false);
  assert.equal('compile' in config, false);
});

test('Viewer起動ではprovider credentialを要求しない', () => {
  const config = parseConfig(baseConfig());
  const environment = buildProviderEnvironment(config, {});

  assert.equal(environment.OPENAI_API_KEY, undefined);
  assert.equal(environment.LLMWIKI_PROVIDER, 'openai');
  assert.equal(environment.LLMWIKI_EMBEDDING_MODEL, 'cl-nagoya/ruri-v3:310m');
});

test('MCP起動ではprovider credentialを必須にする', () => {
  const config = parseConfig(baseConfig());

  assert.throws(() => buildProviderEnvironment(config, {}, true), /LITELLM_MASTER_KEY/);
});
