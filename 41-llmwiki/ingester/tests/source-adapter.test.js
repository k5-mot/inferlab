import assert from 'node:assert/strict';
import {mkdtemp, mkdir, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {removeStaleCompileLock} from '../dist/llmwiki-client.js';
import {createSourceAdapterRegistry, SourceAdapterRegistry} from '../dist/source-adapter.js';

test('input sourceを対応adapterへ委譲する', async () => {
  const commands = [];
  const registry = createSourceAdapterRegistry(async (command) => {
    commands.push(command);
  });
  const source = {
    adapter: 'input',
    id: 'handbook',
    input: 'https://example.test/handbook',
    ingest: {enabled: true, schedule: '0 * * * *', timeoutSeconds: 90},
  };

  await registry.synchronize(source, {projectRoot: '/tmp/wiki', environment: {}});

  assert.deepEqual(commands, [{
    args: ['ingest', 'https://example.test/handbook'],
    timeoutSeconds: 90,
  }]);
});

test('同じkindのadapter重複を拒否する', () => {
  const adapter = {
    kind: 'input',
    synchronize: async () => {},
  };

  assert.throws(() => new SourceAdapterRegistry([adapter, adapter]), /重複/);
});

test('実行processが存在しないcompile lockだけを削除する', async () => {
  const projectRoot = await mkdtemp(join(tmpdir(), 'inferlab-llmwiki-lock-'));
  const lockDirectory = join(projectRoot, '.llmwiki');
  const lockPath = join(lockDirectory, 'lock');
  await mkdir(lockDirectory);

  try {
    await writeFile(lockPath, JSON.stringify({pid: 2_147_483_647}), 'utf8');
    assert.equal(await removeStaleCompileLock(projectRoot), true);
    await assert.rejects(() => readFile(lockPath), {code: 'ENOENT'});

    await writeFile(lockPath, JSON.stringify({pid: process.pid}), 'utf8');
    assert.equal(await removeStaleCompileLock(projectRoot), false);
    assert.deepEqual(JSON.parse(await readFile(lockPath, 'utf8')), {pid: process.pid});
  } finally {
    await rm(projectRoot, {recursive: true, force: true});
  }
});
