import {mkdir} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {buildProviderEnvironment, loadConfig} from './config.js';
import {LlmWikiClient} from './llmwiki-client.js';
import {log} from './logger.js';
import {ViewerProxy} from './proxy.js';
import {SerialJobQueue, startSchedules, WikiJobs} from './scheduler.js';
import {ViewerSupervisor} from './viewer.js';

/**
 * llmwiki runnerを構成し、viewerとschedulerを起動する。
 * @returns startup完了時にresolveするPromise。
 * @throws config、filesystem、viewer、proxy、schedule初期化に失敗した場合。
 * @sideeffect HTTP listener、viewer子process、cron jobを起動する。
 */
async function main(): Promise<void> {
  const mode = process.argv[2];
  if (mode !== undefined && mode !== 'compile') {
    throw new Error(`未対応のrunner modeです: ${mode}`);
  }
  const configPath = process.env.CONFIG_PATH ?? '/app/config.yaml';
  const config = await loadConfig(configPath);
  const environment = buildProviderEnvironment(config, process.env, mode === 'compile');
  await prepareProject(config.projectRoot);

  const binary = resolveLlmWikiBinary();
  const client = new LlmWikiClient(binary, config, environment);
  if (mode === 'compile') {
    await client.compile();
    return;
  }
  const viewer = new ViewerSupervisor(client, config.viewer);
  const proxy = new ViewerProxy(config.viewer);
  const queue = new SerialJobQueue();
  const jobs = new WikiJobs(config, client, viewer);

  await viewer.start();
  await proxy.start();
  const schedules = startSchedules(config, jobs, queue);

  let stopping = false;
  /**
   * signal受信後にschedule、queue、HTTP、viewerの順で停止する。
   * @param signal processが受信したsignal名。
   * @returns shutdown完了時にresolveするPromise。
   * @sideeffect 全serviceを停止してprocessを終了する。
   */
  const shutdown = async (signal: NodeJS.Signals): Promise<void> => {
    if (stopping) return;
    stopping = true;
    log('info', 'runner.stopping', {signal});
    for (const schedule of schedules) schedule.stop();
    await queue.idle();
    await proxy.stop();
    await viewer.stop();
    log('info', 'runner.stopped');
  };

  process.once('SIGTERM', () => void shutdown('SIGTERM'));
  process.once('SIGINT', () => void shutdown('SIGINT'));
  log('info', 'runner.ready', {projectRoot: config.projectRoot});
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

/**
 * package localへ固定installしたllmwiki executableを解決する。
 * @returns llmwiki executableの絶対path。
 */
function resolveLlmWikiBinary(): string {
  const modulePath = fileURLToPath(import.meta.url);
  return path.resolve(path.dirname(modulePath), '..', 'node_modules', '.bin', 'llmwiki');
}

main().catch((error: unknown) => {
  log('error', 'runner.startup.failed', {
    error: error instanceof Error ? error.message : String(error),
  });
  process.exitCode = 1;
});
