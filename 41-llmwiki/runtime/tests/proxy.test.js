import assert from 'node:assert/strict';
import test from 'node:test';
import {normalizeHeaders} from '../dist/proxy.js';

test('viewerのHostとOriginをloopbackへ正規化する', () => {
  const headers = normalizeHeaders(
    {host: 'localhost:34100', origin: 'http://localhost:34100'},
    54321,
  );

  assert.equal(headers.host, '127.0.0.1:54321');
  assert.equal(headers.origin, 'http://127.0.0.1:54321');
});

test('Originがないrequestへ不要なOriginを追加しない', () => {
  const headers = normalizeHeaders({host: 'localhost:34100'}, 54321);

  assert.equal(headers.origin, undefined);
});
