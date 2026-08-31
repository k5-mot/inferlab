import {spawn, type ChildProcess} from 'node:child_process';
import {rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import type {ViewerConfig} from './config.js';
import {log} from './logger.js';

/** Mintlify preview processの起動、停止、ready確認を管理する。 */
export class MintlifySupervisor {
  readonly #config: ViewerConfig;
  #child: ChildProcess | undefined;

  /**
   * Mintlify process supervisorを生成する。
   * @param config workspaceと内部portを含むViewer設定。
   * @returns 初期化済みsupervisor。
   */
  constructor(config: ViewerConfig) {
    this.#config = config;
  }

  /**
   * Mintlify preview processが稼働中か判定する。
   * @returns child processが終了していない場合true。
   */
  isRunning(): boolean {
    return this.#child !== undefined && this.#child.exitCode === null;
  }

  /**
   * Mintlify previewを起動して応答可能になるまで待つ。
   * @returns preview ready時にresolveするPromise。
   * @throws process起動またはstartup timeout時。
   * @sideeffect loopback Mintlify processを起動する。
   */
  async start(): Promise<void> {
    if (this.#child) throw new Error('Mintlify Viewerはすでに起動しています');
    await removePreviewLock(this.#config.mintlify.internalPort);
    const child = spawn(
      'mint',
      [
        'dev',
        '--port',
        String(this.#config.mintlify.internalPort),
        '--no-open',
        '--disable-openapi',
        '--telemetry=false',
      ],
      {
        cwd: this.#config.workspacePath,
        env: process.env,
        stdio: ['ignore', 'pipe', 'pipe'],
        detached: true,
      },
    );
    this.#child = child;
    child.stdout?.on('data', (chunk: Buffer) => process.stdout.write(chunk));
    child.stderr?.on('data', (chunk: Buffer) => process.stderr.write(chunk));
    child.once('exit', (code, signal) => {
      if (this.#child === child) this.#child = undefined;
      log(code === 0 ? 'info' : 'error', 'viewer.mintlify.exited', {code, signal});
    });
    try {
      await waitForHttp(
        this.#config.mintlify.internalPort,
        this.#config.startupTimeoutSeconds,
      );
      log('info', 'viewer.mintlify.ready', {
        port: this.#config.mintlify.internalPort,
      });
    } catch (error) {
      stopProcessGroup(child);
      throw error;
    }
  }

  /**
   * 起動中のMintlify previewを停止する。
   * @returns process終了時にresolveするPromise。
   * @sideeffect child processへSIGTERMを送る。
   */
  async stop(): Promise<void> {
    const child = this.#child;
    if (!child) return;
    this.#child = undefined;
    stopProcessGroup(child);
    await Promise.race([
      new Promise<void>((resolve) => child.once('exit', () => resolve())),
      delay(5000).then(() => undefined),
    ]);
  }
}

/**
 * Mintlify CLIが残したpreview lockを起動前に除去する。
 * @param port 起動予定のpreview port。
 * @returns lock除去完了時にresolveするPromise。
 * @sideeffect user home配下のMintlify lock fileを削除する。
 */
async function removePreviewLock(port: number): Promise<void> {
  const lockPath = path.join(os.homedir(), '.mintlify', 'preview-locks', `${port}.lock`);
  await rm(lockPath, {force: true});
}

/**
 * Mintlify CLIとそこから派生したpreview processをまとめて停止する。
 * @param child process group leaderとして起動したMintlify CLI。
 * @returns 戻り値はない。
 * @sideeffect child process groupへSIGTERMを送る。
 */
function stopProcessGroup(child: ChildProcess): void {
  if (child.pid === undefined) return;
  try {
    process.kill(-child.pid, 'SIGTERM');
  } catch (error) {
    if (!(error instanceof Error && 'code' in error && error.code === 'ESRCH')) throw error;
  }
}

/**
 * MintlifyのHTTP応答をtimeoutまでpollする。
 * @param port loopback port。
 * @param timeoutSeconds 最大待機秒数。
 * @returns HTTP応答確認時にresolveするPromise。
 * @throws timeoutまで応答がない場合。
 */
async function waitForHttp(port: number, timeoutSeconds: number): Promise<void> {
  const deadline = Date.now() + timeoutSeconds * 1000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/`, {
        signal: AbortSignal.timeout(1000),
      });
      if (response.ok) return;
    } catch {
      // CLI起動中の接続失敗はdeadlineまで再試行する。
    }
    await delay(250);
  }
  throw new Error(`Mintlify Viewerが${timeoutSeconds}秒以内に起動しませんでした`);
}
