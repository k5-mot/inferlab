import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {loadConfig} from './config.js';
import {computeSourceDigest, synchronizeContent} from './content.js';
import {log} from './logger.js';
import {ViewerProxy} from './proxy.js';
import {MintlifySupervisor} from './supervisor.js';

/**
 * Mintlify Viewerを構成し、OpenKB生成物の変更監視を開始する。
 * @returns process停止まで継続するPromise。
 * @throws config、content同期、server起動に失敗した場合。
 * @sideeffect workspace生成、Mintlify process、HTTP proxy、poll timerを起動する。
 */
async function main(): Promise<void> {
  const config = await loadConfig(process.env.CONFIG_PATH ?? '/app/config.yaml');
  const modulePath = fileURLToPath(import.meta.url);
  const staticPath = path.resolve(path.dirname(modulePath), '..', 'static');
  let snapshot = await synchronizeContent(config);
  const mintlify = new MintlifySupervisor(config);
  const proxy = new ViewerProxy(config.mintlify, config.workspacePath, staticPath);
  await mintlify.start();
  await proxy.start();
  log('info', 'viewer.ready', {...snapshot});

  let checking = false;
  const timer = setInterval(() => {
    if (checking) return;
    checking = true;
    void (async () => {
      try {
        const digest = await computeSourceDigest(config.sourcePath);
        if (digest === snapshot.digest) {
          if (!mintlify.isRunning()) {
            await mintlify.start();
            log('warn', 'viewer.mintlify.recovered');
          }
          return;
        }
        await mintlify.stop();
        snapshot = await synchronizeContent(config);
        await mintlify.start();
        log('info', 'viewer.content.reloaded', {...snapshot});
      } catch (error) {
        log('error', 'viewer.content.reload_failed', {
          error: error instanceof Error ? error.message : String(error),
        });
      } finally {
        checking = false;
      }
    })();
  }, config.pollSeconds * 1000);

  let stopping = false;
  /**
   * signal受信時にpoll、proxy、Mintlifyを順に停止する。
   * @param signal processが受信したsignal名。
   * @returns shutdown完了時にresolveするPromise。
   * @sideeffect timerとHTTP child processを停止する。
   */
  const shutdown = async (signal: NodeJS.Signals): Promise<void> => {
    if (stopping) return;
    stopping = true;
    clearInterval(timer);
    log('info', 'viewer.stopping', {signal});
    await proxy.stop();
    await mintlify.stop();
    log('info', 'viewer.stopped');
  };
  process.once('SIGTERM', () => void shutdown('SIGTERM'));
  process.once('SIGINT', () => void shutdown('SIGINT'));
}

void main().catch((error: unknown) => {
  log('error', 'viewer.failed', {
    error: error instanceof Error ? error.message : String(error),
  });
  process.exitCode = 1;
});
