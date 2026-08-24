import {spawn, type ChildProcess} from 'node:child_process';
import type {RuntimeConfig, SourceConfig} from './config.js';
import {log} from './logger.js';

export interface CliCommand {
  args: string[];
  timeoutSeconds: number;
}

export class LlmWikiClient {
  readonly #binary: string;
  readonly #config: RuntimeConfig;
  readonly #environment: NodeJS.ProcessEnv;

  /**
   * upstream CLI clientを生成する。
   * @param binary llmwiki executableのpath。
   * @param config runner設定。
   * @param environment upstreamへ渡す環境変数。
   * @returns 初期化済みclient instance。
   */
  constructor(binary: string, config: RuntimeConfig, environment: NodeJS.ProcessEnv) {
    this.#binary = binary;
    this.#config = config;
    this.#environment = environment;
  }

  /**
   * configured sourceをupstreamのsources/へ取り込む。
   * @param source 実効ingest設定を持つsource。
   * @returns ingest完了時にresolveするPromise。
   * @throws CLIが失敗またはtimeoutした場合。
   * @sideeffect project root配下のsources/を更新する。
   */
  async ingest(source: SourceConfig): Promise<void> {
    await this.#run({
      args: ['ingest', source.input],
      timeoutSeconds: source.ingest.timeoutSeconds,
    });
  }

  /**
   * upstream compilerで変更sourceを増分compileする。
   * @returns compile完了時にresolveするPromise。
   * @throws CLIが失敗またはtimeoutした場合。
   * @sideeffect project root配下のwiki/と.llmwiki/を更新する。
   */
  async compile(): Promise<void> {
    const args = ['compile', '--concurrency', String(this.#config.compile.concurrency)];
    if (this.#config.compile.review) args.push('--review');
    await this.#run({args, timeoutSeconds: this.#config.compile.timeoutSeconds});
  }

  /**
   * read-only viewer processをloopbackで起動する。
   * @returns 起動した子process。
   * @sideeffect 指定portでupstream viewerをlistenする。
   */
  startViewer(): ChildProcess {
    return spawn(
      this.#binary,
      ['view', '--port', String(this.#config.viewer.internalPort)],
      {
        cwd: this.#config.projectRoot,
        env: this.#environment,
        stdio: ['ignore', 'pipe', 'pipe'],
      },
    );
  }

  /**
   * 一回限りのupstream CLI commandを実行する。
   * @param command CLI引数とtimeout。
   * @returns command成功時にresolveするPromise。
   * @throws spawn失敗、timeout、非zero終了codeの場合。
   */
  async #run(command: CliCommand): Promise<void> {
    log('info', 'llmwiki.command.started', {command: command.args[0]});
    const child = spawn(this.#binary, command.args, {
      cwd: this.#config.projectRoot,
      env: this.#environment,
      stdio: 'inherit',
    });
    await waitForChild(child, command.timeoutSeconds);
    log('info', 'llmwiki.command.completed', {command: command.args[0]});
  }
}

/**
 * 子processの終了を待ち、timeout時は停止する。
 * @param child 監視する子process。
 * @param timeoutSeconds 許容実行秒数。
 * @returns 正常終了時にresolveするPromise。
 * @throws spawn失敗、timeout、非zero終了codeの場合。
 */
export function waitForChild(child: ChildProcess, timeoutSeconds: number): Promise<void> {
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
      if (code === 0) finish();
      else finish(new Error(`llmwiki commandが終了しました: code=${code}, signal=${signal}`));
    });
  });
}
