import {Cron} from 'croner';
import type {RuntimeConfig, SourceConfig} from './config.js';
import type {LlmWikiClient} from './llmwiki-client.js';
import {log} from './logger.js';
import type {ViewerSupervisor} from './viewer.js';

type Job = () => Promise<void>;

export class SerialJobQueue {
  #tail: Promise<void> = Promise.resolve();

  /**
   * jobを既存jobの末尾へ追加し、同時実行を防ぐ。
   * @param name logへ記録するjob名。
   * @param job 直列実行する非同期処理。
   * @returns queueへ登録されたjobの完了Promise。
   * @sideeffect jobを一度実行して結果をlogへ記録する。
   */
  enqueue(name: string, job: Job): Promise<void> {
    const current = this.#tail.then(async () => {
      log('info', 'job.started', {job: name});
      try {
        await job();
        log('info', 'job.completed', {job: name});
      } catch (error) {
        log('error', 'job.failed', {job: name, error: errorMessage(error)});
      }
    });
    this.#tail = current;
    return current;
  }

  /**
   * queue済みjobがすべて完了するまで待機する。
   * @returns queue末尾jobの完了Promise。
   */
  idle(): Promise<void> {
    return this.#tail;
  }
}

export class WikiJobs {
  readonly #config: RuntimeConfig;
  readonly #client: LlmWikiClient;
  readonly #viewer: ViewerSupervisor;

  /**
   * ingestとcompileのapplication jobを生成する。
   * @param config runner設定。
   * @param client upstream CLI client。
   * @param viewer compile後に更新するviewer supervisor。
   * @returns 初期化済みjob集合。
   */
  constructor(config: RuntimeConfig, client: LlmWikiClient, viewer: ViewerSupervisor) {
    this.#config = config;
    this.#client = client;
    this.#viewer = viewer;
  }

  /**
   * sourceを取り込み、設定時は続けてcompileする。
   * @param source 取り込むsource設定。
   * @returns ingestと任意compileの完了Promise。
   * @throws upstream CLIまたはviewer更新に失敗した場合。
   */
  async ingest(source: SourceConfig): Promise<void> {
    await this.#client.ingest(source);
    if (this.#config.compile.onIngest) await this.compile();
  }

  /**
   * Wikiを増分compileし、成功後にviewer snapshotを更新する。
   * @returns compileとviewer再起動の完了Promise。
   * @throws upstream CLIまたはviewer更新に失敗した場合。
   */
  async compile(): Promise<void> {
    await this.#client.compile();
    await this.#viewer.restart();
  }
}

/**
 * 設定されたcron jobを登録する。
 * @param config scheduleとtimezoneを含むrunner設定。
 * @param jobs ingestとcompileの実処理。
 * @param queue jobを直列化するqueue。
 * @returns 停止時に破棄するCron instance一覧。
 * @throws cron式またはtimezoneが無効な場合。
 * @sideeffect 有効なscheduleを直ちに登録する。
 */
export function startSchedules(
  config: RuntimeConfig,
  jobs: WikiJobs,
  queue: SerialJobQueue,
): Cron[] {
  validateSchedule(config.compile.schedule, config.timezone);
  for (const source of config.sources) validateSchedule(source.ingest.schedule, config.timezone);

  const schedules: Cron[] = [];
  for (const source of config.sources) {
    if (!source.ingest.enabled) continue;
    schedules.push(new Cron(
      source.ingest.schedule,
      {timezone: config.timezone, protect: true},
      () => void queue.enqueue(`ingest:${source.id}`, () => jobs.ingest(source)),
    ));
  }
  if (config.compile.enabled) {
    schedules.push(new Cron(
      config.compile.schedule,
      {timezone: config.timezone, protect: true},
      () => void queue.enqueue('compile', () => jobs.compile()),
    ));
  }
  log('info', 'scheduler.ready', {jobs: schedules.length, timezone: config.timezone});
  return schedules;
}

/**
 * cron式とtimezoneをrunner起動時に検証する。
 * @param expression 検証するcron式。
 * @param timezone IANA timezone名。
 * @returns 戻り値はない。
 * @throws Cronerが設定を解釈できない場合。
 */
function validateSchedule(expression: string, timezone: string): void {
  const schedule = new Cron(expression, {timezone, paused: true});
  schedule.stop();
}

/**
 * unknown errorをcredential非依存のlog文字列へ変換する。
 * @param error catchした値。
 * @returns logへ記録できるmessage。
 */
function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
