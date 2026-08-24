import {spawn, type ChildProcess} from 'node:child_process';
import {readFile, unlink} from 'node:fs/promises';
import path from 'node:path';
import type {RuntimeConfig, SourceConfig} from './config.js';
import {log} from './logger.js';
import {createSourceAdapterRegistry, type InputCommand, type SourceAdapterRegistry} from './source-adapter.js';
import {signalViewerReload} from './viewer-generation.js';

export class LlmWikiClient {
  readonly #binary: string;
  readonly #config: RuntimeConfig;
  readonly #environment: NodeJS.ProcessEnv;
  readonly #sourceAdapters: SourceAdapterRegistry;

  /**
   * upstream CLI clientを生成する。
   * @param binary llmwiki executableのpath。
   * @param config Ingester設定。
   * @param environment upstreamへ渡す環境変数。
   * @returns 初期化済みclient instance。
   */
  constructor(binary: string, config: RuntimeConfig, environment: NodeJS.ProcessEnv) {
    this.#binary = binary;
    this.#config = config;
    this.#environment = environment;
    this.#sourceAdapters = createSourceAdapterRegistry((command) => this.#run(command));
  }

  /**
   * configured sourceをupstreamのsources/へ取り込む。
   * @param source 実効ingest設定を持つsource。
   * @returns ingest完了時にresolveするPromise。
   * @throws CLIが失敗またはtimeoutした場合。
   * @sideeffect project root配下のsources/を更新する。
   */
  async ingest(source: SourceConfig): Promise<void> {
    await this.#sourceAdapters.synchronize(source, {
      projectRoot: this.#config.projectRoot,
      environment: this.#environment,
    });
  }

  /**
   * upstream compilerで変更sourceを増分compileする。
   * @returns compile完了時にresolveするPromise。
   * @throws CLIが失敗またはtimeoutした場合。
   * @sideeffect project root配下のwiki/と.llmwiki/を更新する。
   */
  async compile(): Promise<void> {
    await removeStaleCompileLock(this.#config.projectRoot);
    const args = ['compile', '--concurrency', String(this.#config.compile.concurrency)];
    if (this.#config.compile.review) args.push('--review');
    await this.#run({args, timeoutSeconds: this.#config.compile.timeoutSeconds});
    await signalViewerReload(this.#config.projectRoot);
  }

  /**
   * Wikiへrule-based lintを実行する。
   * @returns lint完了時にresolveするPromise。
   * @throws command起動またはtimeoutに失敗した場合。
   * @sideeffect `.llmwiki/last-lint.json`を更新する。
   */
  async lint(): Promise<void> {
    await this.#run({
      args: ['lint'],
      timeoutSeconds: this.#config.compile.timeoutSeconds,
      acceptedExitCodes: [0, 1],
    });
  }

  /**
   * Wiki品質evalを設定suiteで実行する。
   * @returns eval完了時にresolveするPromise。
   * @throws command起動またはtimeoutに失敗した場合。
   * @sideeffect `.llmwiki/eval/history.jsonl`へ評価結果を追記する。
   */
  async eval(): Promise<void> {
    await this.#run({
      args: ['eval', '--suite', this.#config.quality.eval.suite],
      timeoutSeconds: this.#config.compile.timeoutSeconds,
      acceptedExitCodes: [0, 1],
    });
  }

  /**
   * 一回限りのupstream CLI commandを実行する。
   * @param command CLI引数とtimeout。
   * @returns command成功時にresolveするPromise。
   * @throws spawn失敗、timeout、非zero終了codeの場合。
   */
  async #run(command: InputCommand): Promise<void> {
    log('info', 'llmwiki.command.started', {command: command.args[0]});
    const child = spawn(this.#binary, command.args, {
      cwd: this.#config.projectRoot,
      env: this.#environment,
      stdio: 'inherit',
    });
    await waitForChild(child, command.timeoutSeconds, command.acceptedExitCodes);
    log('info', 'llmwiki.command.completed', {command: command.args[0]});
  }
}

/**
 * 永続volumeへ残ったcompile lockをPID確認後に除去する。
 * @param projectRoot LLMWiki project root。
 * @returns stale lockを削除した場合はtrue、それ以外はfalse。
 * @throws lock形式が不正、またはfile操作に失敗した場合。
 * @sideeffect 実行processが存在しない場合だけ.llmwiki/lockを削除する。
 */
export async function removeStaleCompileLock(projectRoot: string): Promise<boolean> {
  const lockPath = path.join(projectRoot, '.llmwiki', 'lock');
  let lockText: string;
  try {
    lockText = await readFile(lockPath, 'utf8');
  } catch (error) {
    if (isFileNotFound(error)) return false;
    throw error;
  }
  const lockValue: unknown = JSON.parse(lockText);
  const pid = lockPid(lockValue);
  if (isProcessRunning(pid)) return false;
  await unlink(lockPath);
  log('warn', 'llmwiki.compile.stale_lock_removed', {pid});
  return true;
}

/**
 * 未検証lock JSONから正のPIDを取得する。
 * @param value JSON parserが返した未検証値。
 * @returns lockを所有したprocessのPID。
 * @throws `{pid: positive integer}`形式でない場合。
 */
function lockPid(value: unknown): number {
  if (
    typeof value !== 'object'
    || value === null
    || !('pid' in value)
    || typeof value.pid !== 'number'
    || !Number.isSafeInteger(value.pid)
    || value.pid <= 0
  ) {
    throw new Error('llmwiki compile lockの形式が不正です');
  }
  return value.pid;
}

/**
 * PIDが現在のPID namespaceで実行中か確認する。
 * @param pid 確認するprocess ID。
 * @returns processが存在するか、権限不足で判定不能ならtrue。
 * @throws ESRCHとEPERM以外のprocess確認errorが発生した場合。
 */
function isProcessRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error instanceof Error && 'code' in error && error.code === 'ESRCH') return false;
    if (error instanceof Error && 'code' in error && error.code === 'EPERM') return true;
    throw error;
  }
}

/**
 * filesystem errorがfile未存在を表すか判定する。
 * @param error filesystem APIから受け取った値。
 * @returns error codeがENOENTならtrue。
 */
function isFileNotFound(error: unknown): boolean {
  return error instanceof Error && 'code' in error && error.code === 'ENOENT';
}

/**
 * 子processの終了を待ち、timeout時は停止する。
 * @param child 監視する子process。
 * @param timeoutSeconds 許容実行秒数。
 * @returns 正常終了時にresolveするPromise。
 * @throws spawn失敗、timeout、非zero終了codeの場合。
 */
export function waitForChild(
  child: ChildProcess,
  timeoutSeconds: number,
  acceptedExitCodes: readonly number[] = [0],
): Promise<void> {
  return new Promise((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill('SIGTERM');
      reject(new Error(`llmwiki commandが${timeoutSeconds}秒でtimeoutしました`));
    }, timeoutSeconds * 1000);

    /** 子process監視を一度だけ完了させる。 */
    const finish = (error?: Error): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error);
      else resolve();
    };

    child.once('error', (error) => finish(error));
    child.once('exit', (code, signal) => {
      if (code !== null && acceptedExitCodes.includes(code)) finish();
      else finish(new Error(`llmwiki commandが終了しました: code=${code}, signal=${signal}`));
    });
  });
}
