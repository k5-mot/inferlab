import {mkdir} from 'node:fs/promises';
import path from 'node:path';
import {buildProviderEnvironment, loadConfig, validateSourceEnvironment} from './config.js';
import {LlmWikiClient} from './llmwiki-client.js';
import {log} from './logger.js';
import {SerialJobQueue, startSchedules, WikiJobs} from './scheduler.js';
import {resolveLlmWikiBinary} from './upstream.js';

/**
 * Ingesterを構成し、sourceとcompileのschedulerを起動する。
 * @returns startup完了時にresolveするPromise。
 * @throws config、filesystem、source、schedule初期化に失敗した場合。
 * @sideeffect source、compile、lint、evalのcron jobを起動する。
 */
async function main(): Promise<void> {
  const mode = process.argv[2];
  if (mode !== undefined && mode !== 'compile' && mode !== 'ingest') {
    throw new Error(`未対応のIngester modeです: ${mode}`);
  }
  const configPath = process.env.CONFIG_PATH ?? '/app/config.yaml';
  const config = await loadConfig(configPath);
  const environment = buildProviderEnvironment(config, process.env, mode === 'compile');
  validateSourceEnvironment(config, process.env);
  await prepareProject(config.projectRoot);

  const binary = resolveLlmWikiBinary();
  const client = new LlmWikiClient(binary, config, environment);
  if (mode === 'compile') {
    const jobs = new WikiJobs(config, client);
    await jobs.compile();
    return;
  }
  if (mode === 'ingest') {
    const sourceId = process.argv[3];
    if (!sourceId) throw new Error('ingest modeにはsource IDが必要です');
    const source = config.sources.find((candidate) => candidate.id === sourceId);
    if (!source) throw new Error(`source IDが見つかりません: ${sourceId}`);
    const jobs = new WikiJobs(config, client);
    await jobs.ingest(source);
    return;
  }
  const queue = new SerialJobQueue();
  const jobs = new WikiJobs(config, client);

  const schedules = startSchedules(config, jobs, queue);

  let stopping = false;
  /**
   * signal受信後にscheduleとqueueを停止する。
   * @param signal processが受信したsignal名。
   * @returns shutdown完了時にresolveするPromise。
   * @sideeffect 全serviceを停止してprocessを終了する。
   */
  const shutdown = async (signal: NodeJS.Signals): Promise<void> => {
    if (stopping) return;
    stopping = true;
    log('info', 'ingester.stopping', {signal});
    for (const schedule of schedules) schedule.stop();
    await queue.idle();
    log('info', 'ingester.stopped');
  };

  process.once('SIGTERM', () => void shutdown('SIGTERM'));
  process.once('SIGINT', () => void shutdown('SIGINT'));
  log('info', 'ingester.ready', {projectRoot: config.projectRoot});
}

/**
 * upstreamが期待するproject directoryを初回起動前に準備する。
 * @param projectRoot llmwiki project root。
 * @returns directory作成完了時にresolveするPromise。
 * @sideeffect project root配下へ必要directoryを作成する。
 */
async function prepareProject(projectRoot: string): Promise<void> {
  await Promise.all([
    mkdir(path.join(projectRoot, 'sources'), {recursive: true}),
    mkdir(path.join(projectRoot, 'wiki'), {recursive: true}),
    mkdir(path.join(projectRoot, '.llmwiki'), {recursive: true}),
    mkdir(path.join(projectRoot, 'artifacts'), {recursive: true}),
  ]);
}

main().catch((error: unknown) => {
  log('error', 'ingester.startup.failed', {
    error: error instanceof Error ? error.message : String(error),
  });
  process.exitCode = 1;
});
