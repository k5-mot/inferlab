import {writeFile} from 'node:fs/promises';
import path from 'node:path';

const GENERATION_FILE = path.join('.llmwiki', 'viewer-generation');

/**
 * compile済みWikiの世代を共有volumeへ記録する。
 * @param projectRoot llmwiki project root。
 * @returns marker書込完了時にresolveするPromise。
 * @sideeffect `.llmwiki/viewer-generation`を更新する。
 */
export async function signalViewerReload(projectRoot: string): Promise<void> {
  await writeFile(
    path.join(projectRoot, GENERATION_FILE),
    `${new Date().toISOString()} ${process.pid}\n`,
    'utf8',
  );
}
