import assert from 'node:assert/strict';
import {mkdtemp, readFile, readdir, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {
  fetchCouchDbDocuments,
  synchronizeCouchDbSource,
} from '../dist/couchdb-source.js';

/**
 * test用の正規化済みCouchDB source設定を生成する。
 * @param overrides 上書きするsource設定。
 * @returns CouchDB adapterへ渡せるsource設定。
 */
function couchDbSource(overrides = {}) {
  return {
    adapter: 'couchdb',
    id: 'obsidian-couchdb',
    url: 'http://couchdb:5984',
    database: 'obsidian',
    usernameEnv: 'COUCHDB_USERNAME',
    passwordEnv: 'COUCHDB_PASSWORD',
    excludePathPrefixes: ['ix:'],
    maxDocuments: 1000,
    ingest: {enabled: true, schedule: '0 * * * *', timeoutSeconds: 10},
    ...overrides,
  };
}

/**
 * `_all_docs`互換responseを返すFetch fakeを生成する。
 * @param rows responseへ含めるrow配列。
 * @param inspect request内容を検証するcallback。
 * @returns Fetchと同じ引数で呼び出せるasync関数。
 */
function couchDbFetch(rows, inspect = () => {}) {
  return async (input, init) => {
    inspect(input, init);
    return new Response(JSON.stringify({rows}), {
      status: 200,
      headers: {'content-type': 'application/json'},
    });
  };
}

test('LiveSync親documentを順序付きchunkから復元する', async () => {
  const rows = [
    {doc: {_id: 'note-1', type: 'plain', path: 'notes/設計.md', children: ['leaf-b', 'leaf-a']}},
    {doc: {_id: 'leaf-a', type: 'leaf', data: '後半'}},
    {doc: {_id: 'leaf-b', type: 'leaf', data: '# 前半\n'}},
    {doc: {_id: 'hidden', type: 'plain', path: '.obsidian/internal.md', children: []}},
    {doc: {_id: 'livesync', type: 'plain', path: 'ix:laptop/CONFIG/app.json.md', children: []}},
    {doc: {_id: 'text', type: 'plain', path: 'notes/readme.txt', children: []}},
    {doc: {_id: 'deleted', type: 'plain', path: 'notes/deleted.md', deleted: true, children: []}},
  ];
  const fetchImpl = couchDbFetch(rows, (input, init) => {
    const endpoint = new URL(input);
    assert.equal(endpoint.pathname, '/obsidian/_all_docs');
    assert.equal(endpoint.searchParams.get('include_docs'), 'true');
    assert.equal(init.headers.authorization, 'Basic cmVhZGVyOnNlY3JldA==');
  });

  const documents = await fetchCouchDbDocuments(
    couchDbSource(),
    {COUCHDB_USERNAME: 'reader', COUCHDB_PASSWORD: 'secret'},
    fetchImpl,
  );

  assert.deepEqual(documents, [{
    id: 'note-1',
    path: 'notes/設計.md',
    content: '# 前半\n後半',
  }]);
});

test('snapshotから消えたdocumentのsource fileを削除する', async () => {
  const projectRoot = await mkdtemp(join(tmpdir(), 'inferlab-llmwiki-'));
  let rows = [
    {doc: {_id: 'note-1', type: 'plain', path: 'one.md', children: ['leaf-1']}},
    {doc: {_id: 'leaf-1', type: 'leaf', data: '# One'}},
    {doc: {_id: 'note-2', type: 'plain', path: 'two.md', children: ['leaf-2']}},
    {doc: {_id: 'leaf-2', type: 'leaf', data: '# Two'}},
  ];
  const dynamicFetch = async (input, init) => {
    void input;
    void init;
    return new Response(JSON.stringify({rows}), {status: 200});
  };

  try {
    const first = await synchronizeCouchDbSource(
      projectRoot,
      couchDbSource(),
      {COUCHDB_USERNAME: 'reader', COUCHDB_PASSWORD: 'secret'},
      dynamicFetch,
    );
    assert.equal(first.created, 2);
    assert.equal(first.removed, 0);

    rows = rows.filter((row) => !['note-2', 'leaf-2'].includes(row.doc._id));
    const second = await synchronizeCouchDbSource(
      projectRoot,
      couchDbSource(),
      {COUCHDB_USERNAME: 'reader', COUCHDB_PASSWORD: 'secret'},
      dynamicFetch,
    );
    assert.equal(second.unchanged, 1);
    assert.equal(second.removed, 1);
    assert.equal((await readdir(join(projectRoot, 'sources'))).length, 1);

    const manifest = JSON.parse(await readFile(
      join(projectRoot, '.llmwiki', 'couchdb-source-obsidian-couchdb.json'),
      'utf8',
    ));
    assert.deepEqual(Object.keys(manifest), ['note-1']);
  } finally {
    await rm(projectRoot, {recursive: true, force: true});
  }
});
