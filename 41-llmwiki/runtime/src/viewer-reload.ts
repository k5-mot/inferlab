import type {RuntimeConfig} from './config.js';
import {log} from './logger.js';
import {readViewerGeneration} from './viewer-generation.js';
import type {ViewerSupervisor} from './viewer.js';

/** 共有volumeのgeneration markerを監視してViewerを更新する。 */
export class ViewerReloadMonitor {
  readonly #projectRoot: string;
  readonly #pollMilliseconds: number;
  readonly #viewer: ViewerSupervisor;
  #generation: string | undefined;
  #timer: NodeJS.Timeout | undefined;
  #checking = false;

  /**
   * Viewer reload monitorを生成する。
   * @param projectRoot llmwiki project root。
   * @param config polling間隔を含むViewer設定。
   * @param viewer 再起動対象のViewer supervisor。
   * @returns 初期化済みmonitor。
   */
  constructor(
    projectRoot: string,
    config: RuntimeConfig['viewer'],
    viewer: ViewerSupervisor,
  ) {
    this.#projectRoot = projectRoot;
    this.#pollMilliseconds = config.reloadPollSeconds * 1000;
    this.#viewer = viewer;
  }

  /**
   * 現在世代を記録してpollingを開始する。
   * @returns monitor開始時にresolveするPromise。
   * @throws 初期marker読込に失敗した場合。
   * @sideeffect 定期timerを開始する。
   */
  async start(): Promise<void> {
    if (this.#timer) throw new Error('viewer reload monitorはすでに起動しています');
    this.#generation = await readViewerGeneration(this.#projectRoot);
    this.#timer = setInterval(() => void this.#check(), this.#pollMilliseconds);
  }

  /**
   * generation markerのpollingを停止する。
   * @returns 戻り値はない。
   * @sideeffect 定期timerを停止する。
   */
  stop(): void {
    if (this.#timer) clearInterval(this.#timer);
    this.#timer = undefined;
  }

  /**
   * generation変更時だけViewerを再起動する。
   * @returns 確認完了時にresolveするPromise。
   * @sideeffect marker変更時にViewer processを再起動する。
   */
  async #check(): Promise<void> {
    if (this.#checking) return;
    this.#checking = true;
    try {
      const generation = await readViewerGeneration(this.#projectRoot);
      if (generation === this.#generation) return;
      await this.#viewer.restart();
      this.#generation = generation;
      log('info', 'viewer.reloaded', {generation: generation?.trim()});
    } catch (error) {
      log('error', 'viewer.reload.failed', {
        error: error instanceof Error ? error.message : String(error),
      });
    } finally {
      this.#checking = false;
    }
  }
}
