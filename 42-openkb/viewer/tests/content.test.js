import assert from 'node:assert/strict';
import {mkdtemp, mkdir, readFile, rm, writeFile} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {computeSourceDigest, synchronizeContent} from '../dist/content.js';

/**
 * testごとのsource、workspace、static directoryを作成する。
 * @returns 一時directoryとViewer設定。
 * @sideeffect OS temporary directory配下へファイルを作成する。
 */
async function createFixture() {
  const root = await mkdtemp(path.join(os.tmpdir(), 'openkb-viewer-'));
  const sourcePath = path.join(root, 'source');
  const workspacePath = path.join(root, 'workspace');
  return {
    root,
    sourcePath,
    workspacePath,
    config: {
      sourcePath,
      workspacePath,
      pollSeconds: 5,
      startupTimeoutSeconds: 120,
      mintlify: {
        internalPort: 3000,
        publicHost: '0.0.0.0',
        publicPort: 8080,
        name: 'OpenKB Knowledge',
        theme: 'maple',
        colors: {primary: '#0f766e', light: '#14b8a6', dark: '#172033'},
      },
    },
  };
}

/** Generated Wikiの階層、link、graphがMintlify workspaceへ反映されることを検証する。 */
test('OpenKB MarkdownからMintlify contentとgraphを生成する', async (context) => {
  const fixture = await createFixture();
  context.after(async () => rm(fixture.root, {recursive: true, force: true}));
  await mkdir(path.join(fixture.sourcePath, 'concepts'), {recursive: true});
  await mkdir(path.join(fixture.sourcePath, 'entities'), {recursive: true});
  await writeFile(
    path.join(fixture.sourcePath, 'concepts', 'alpha.md'),
    '---\ntitle: Alpha\ndescription: 最初の記事\n---\n\n# Alpha\n\n[[Beta|関連項目]]\n',
    'utf8',
  );
  await writeFile(
    path.join(fixture.sourcePath, 'entities', 'beta.md'),
    '---\ntitle: Beta\n---\n\n# Beta\n',
    'utf8',
  );

  const snapshot = await synchronizeContent(fixture.config);
  const alpha = await readFile(
    path.join(fixture.workspacePath, 'wiki', 'concepts', 'alpha.mdx'),
    'utf8',
  );
  const docs = JSON.parse(await readFile(path.join(fixture.workspacePath, 'docs.json'), 'utf8'));
  const graphSource = await readFile(
    path.join(fixture.workspacePath, 'viewer-data', 'graph-data.js'),
    'utf8',
  );
  const graph = JSON.parse(
    graphSource.replace(/^window\.__OPENKB_GRAPH__ = /, '').replace(/;\n$/, ''),
  );

  assert.equal(snapshot.pageCount, 2);
  assert.equal(snapshot.edgeCount, 1);
  assert.match(alpha, /\[関連項目]\(\/wiki\/entities\/beta\)/);
  assert.equal(docs.navigation.groups[1].pages[0].group, 'Concepts');
  assert.deepEqual(graph.edges[0].data, {
    id: 'concepts/alpha->entities/beta',
    source: 'concepts/alpha',
    target: 'entities/beta',
  });
});

/** source未作成時にも空状態のMintlify siteが生成されることを検証する。 */
test('Generated Wikiが空でもViewerを生成する', async (context) => {
  const fixture = await createFixture();
  context.after(async () => rm(fixture.root, {recursive: true, force: true}));

  const snapshot = await synchronizeContent(fixture.config);
  const emptyPage = await readFile(
    path.join(fixture.workspacePath, 'generated-empty.mdx'),
    'utf8',
  );

  assert.equal(snapshot.pageCount, 0);
  assert.match(emptyPage, /初回compile/);
  assert.equal(snapshot.digest, await computeSourceDigest(fixture.sourcePath));
});

/** rawとreportsがViewerへ公開されないことを検証する。 */
test('OpenKB内部directoryを公開対象から除外する', async (context) => {
  const fixture = await createFixture();
  context.after(async () => rm(fixture.root, {recursive: true, force: true}));
  await mkdir(path.join(fixture.sourcePath, 'raw'), {recursive: true});
  await writeFile(path.join(fixture.sourcePath, 'raw', 'secret.md'), '# raw', 'utf8');

  const snapshot = await synchronizeContent(fixture.config);

  assert.equal(snapshot.pageCount, 0);
});
