import {buildProviderEnvironment, loadConfig} from './config.js';
import {log} from './logger.js';
import {ViewerProxy} from './proxy.js';
import {resolveLlmWikiBinary} from './upstream.js';
import {ViewerReloadMonitor} from './viewer-reload.js';
import {ViewerSupervisor} from './viewer.js';

/**
 * Viewer runtimeを構成し、共有volumeのWikiを公開する。
 * @returns runtime停止時にresolveするPromise。
 * @throws config、Viewer、proxy初期化に失敗した場合。
 * @sideeffect Viewer、HTTP proxy、generation monitorを起動する。
 */
async function main(): Promise<void> {
  const configPath = process.env.CONFIG_PATH ?? '/app/config.yaml';
  const config = await loadConfig(configPath);
  const environment = buildProviderEnvironment(config, process.env);
  const binary = resolveLlmWikiBinary();
  const viewer = new ViewerSupervisor(binary, environment, config.projectRoot, config.viewer);
  const proxy = new ViewerProxy(config.viewer);
  const monitor = new ViewerReloadMonitor(config.projectRoot, config.viewer, viewer);

  await viewer.start();
  await proxy.start();
  await monitor.start();

  let stopping = false;
  /**
   * signal受信後にmonitor、proxy、Viewerの順で停止する。
   * @param signal processが受信したsignal名。
   * @returns shutdown完了時にresolveするPromise。
   * @sideeffect runtime serviceを停止する。
   */
  const shutdown = async (signal: NodeJS.Signals): Promise<void> => {
    if (stopping) return;
    stopping = true;
    log('info', 'llmwiki.runtime.stopping', {signal});
    monitor.stop();
    await proxy.stop();
    await viewer.stop();
    log('info', 'llmwiki.runtime.stopped');
  };

  process.once('SIGTERM', () => void shutdown('SIGTERM'));
  process.once('SIGINT', () => void shutdown('SIGINT'));
  log('info', 'llmwiki.runtime.ready', {projectRoot: config.projectRoot});
}

main().catch((error: unknown) => {
  log('error', 'llmwiki.runtime.failed', {
    error: error instanceof Error ? error.message : String(error),
  });
  process.exitCode = 1;
});
