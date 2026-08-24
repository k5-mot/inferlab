import path from 'node:path';
import {fileURLToPath} from 'node:url';

/**
 * Runtime packageへ固定installしたllmwiki executableを解決する。
 * @returns llmwiki executableの絶対path。
 */
export function resolveLlmWikiBinary(): string {
  const modulePath = fileURLToPath(import.meta.url);
  return path.resolve(path.dirname(modulePath), '..', 'node_modules', '.bin', 'llmwiki');
}
