import {readFile, writeFile} from 'node:fs/promises';
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

/**
 * 共有volume上のViewer世代markerを読み取る。
 * @param projectRoot llmwiki project root。
 * @returns marker内容。未作成時はundefined。
 * @throws 未作成以外のfile読込errorが発生した場合。
 */
export async function readViewerGeneration(projectRoot: string): Promise<string | undefined> {
  try {
    return await readFile(path.join(projectRoot, GENERATION_FILE), 'utf8');
  } catch (error) {
    if (error instanceof Error && 'code' in error && error.code === 'ENOENT') return undefined;
    throw error;
  }
}
