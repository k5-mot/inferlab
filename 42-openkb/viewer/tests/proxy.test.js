import assert from 'node:assert/strict';
import test from 'node:test';
import {normalizeHeaders} from '../dist/proxy.js';

/** client側のHostとOriginがMintlify内部addressへ置換されることを検証する。 */
test('HostとOriginをloopbackへ正規化する', () => {
  const headers = normalizeHeaders(
    {host: 'localhost:34201', origin: 'http://localhost:34201'},
    3000,
  );

  assert.equal(headers.host, '127.0.0.1:3000');
  assert.equal(headers.origin, 'http://127.0.0.1:3000');
});

/** Originなしrequestへ不要なheaderを追加しないことを検証する。 */
test('Originがない場合は追加しない', () => {
  const headers = normalizeHeaders({host: 'localhost:34201'}, 3000);

  assert.equal(headers.origin, undefined);
});
