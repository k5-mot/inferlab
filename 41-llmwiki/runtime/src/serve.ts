import {spawn} from 'node:child_process';
import {buildProviderEnvironment, loadConfig} from './config.js';
import {resolveLlmWikiBinary} from './upstream.js';

/**
 * upstream MCP stdio serverを設定済み環境で起動する。
 * @returns MCP process終了時にresolveするPromise。
 * @throws config読込、process起動、非zero終了に失敗した場合。
 * @sideeffect stdin/stdoutをupstream `llmwiki serve`へ接続する。
 */
async function main(): Promise<void> {
  const configPath = process.env.CONFIG_PATH ?? '/app/config.yaml';
  const config = await loadConfig(configPath);
  const environment = buildProviderEnvironment(config, process.env, true);
  const child = spawn(
    resolveLlmWikiBinary(),
    ['serve', '--root', config.projectRoot],
    {env: environment, stdio: 'inherit'},
  );
  const result = await new Promise<{code: number | null; signal: NodeJS.Signals | null}>(
    (resolve, reject) => {
      child.once('error', reject);
      child.once('exit', (code, signal) => resolve({code, signal}));
    },
  );
  if (result.code !== 0) {
    throw new Error(`llmwiki serveが異常終了しました: code=${result.code} signal=${result.signal}`);
  }
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`llmwiki serve wrapper failed: ${message}\n`);
  process.exitCode = 1;
});
