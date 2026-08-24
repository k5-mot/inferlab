import {spawn, type ChildProcess} from 'node:child_process';
import {setTimeout as delay} from 'node:timers/promises';
import type {RuntimeConfig} from './config.js';
import {log} from './logger.js';

export class ViewerSupervisor {
  readonly #binary: string;
  readonly #environment: NodeJS.ProcessEnv;
  readonly #projectRoot: string;
  readonly #config: RuntimeConfig['viewer'];
  #child: ChildProcess | undefined;

  /**
   * viewer process supervisorを生成する。
   * @param binary llmwiki executableのpath。
   * @param environment upstreamへ渡す環境変数。
   * @param projectRoot llmwiki project root。
   * @param config viewer設定。
   * @returns 初期化済みsupervisor。
   */
  constructor(
    binary: string,
    environment: NodeJS.ProcessEnv,
    projectRoot: string,
    config: RuntimeConfig['viewer'],
  ) {
    this.#binary = binary;
    this.#environment = environment;
    this.#projectRoot = projectRoot;
    this.#config = config;
  }

  /**
   * viewerを起動し、health endpointが応答するまで待機する。
   * @returns viewer ready時にresolveするPromise。
   * @throws viewerが起動timeoutした場合。
   * @sideeffect loopback viewer processを起動する。
   */
  async start(): Promise<void> {
    if (this.#child) throw new Error('viewerはすでに起動しています');
    const child = spawn(
      this.#binary,
      ['view', '--port', String(this.#config.internalPort)],
      {
        cwd: this.#projectRoot,
        env: this.#environment,
        stdio: ['ignore', 'pipe', 'pipe'],
      },
    );
    this.#child = child;
    child.stdout?.on('data', (chunk: Buffer) => process.stdout.write(chunk));
    child.stderr?.on('data', (chunk: Buffer) => process.stderr.write(chunk));
    child.once('exit', (code, signal) => {
      if (this.#child === child) this.#child = undefined;
      log(code === 0 ? 'info' : 'error', 'viewer.exited', {code, signal});
    });
    try {
      await waitForViewer(this.#config.internalPort, this.#config.startupTimeoutSeconds);
      log('info', 'viewer.ready', {port: this.#config.internalPort});
    } catch (error) {
      child.kill('SIGTERM');
      throw error;
    }
  }

  /**
   * viewerを停止する。
   * @returns process終了時にresolveするPromise。
   * @sideeffect 起動中viewerへSIGTERMを送る。
   */
  async stop(): Promise<void> {
    const child = this.#child;
    if (!child) return;
    this.#child = undefined;
    child.kill('SIGTERM');
    await Promise.race([
      new Promise<void>((resolve) => child.once('exit', () => resolve())),
      delay(5000).then(() => undefined),
    ]);
  }

  /**
   * compile後の新しいfilesystem snapshotでviewerを再生成する。
   * @returns 再起動完了時にresolveするPromise。
   * @throws 新しいviewerの起動に失敗した場合。
   * @sideeffect viewerを停止して再起動する。
   */
  async restart(): Promise<void> {
    await this.stop();
    await this.start();
  }
}

/**
 * viewer health endpointが成功するまでpollする。
 * @param port viewerのloopback port。
 * @param timeoutSeconds 最大待機秒数。
 * @returns health成功時にresolveするPromise。
 * @throws timeoutまでhealthが成功しない場合。
 */
async function waitForViewer(port: number, timeoutSeconds: number): Promise<void> {
  const deadline = Date.now() + timeoutSeconds * 1000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/api/health`, {
        signal: AbortSignal.timeout(1000),
      });
      if (response.ok) return;
    } catch {
      // viewer起動中の接続失敗はdeadlineまで再試行する。
    }
    await delay(100);
  }
  throw new Error(`viewerが${timeoutSeconds}秒以内に起動しませんでした`);
}
