import assert from 'node:assert/strict';
import test from 'node:test';
import {parseConfig} from '../dist/config.js';

/**
 * Viewer test用の最小有効設定を返す。
 * @returns 共通config.yaml相当のobject。
 */
function baseConfig() {
  return {
    openkb: {generated_wiki_path: '/openkb-kbs/internal-wiki/wiki'},
    viewer: {
      workspace_path: '/data/mintlify/site',
      poll_seconds: 5,
      startup_timeout_seconds: 120,
      mintlify: {
        internal_port: 3000,
        public_host: '0.0.0.0',
        public_port: 8080,
        name: 'OpenKB Knowledge',
        theme: 'maple',
        colors: {primary: '#0f766e', light: '#14b8a6', dark: '#172033'},
      },
    },
  };
}

/** Viewer設定がsnake_caseからruntime型へ変換されることを検証する。 */
test('Viewer設定を正規化する', () => {
  const config = parseConfig(baseConfig());

  assert.equal(config.sourcePath, '/openkb-kbs/internal-wiki/wiki');
  assert.equal(config.mintlify.publicPort, 8080);
  assert.equal(config.mintlify.colors.primary, '#0f766e');
});

/** 不正なcolor設定が起動前に拒否されることを検証する。 */
test('Mintlify colorはhex形式を必須にする', () => {
  const config = baseConfig();
  config.viewer.mintlify.colors.primary = 'teal';

  assert.throws(() => parseConfig(config));
});
