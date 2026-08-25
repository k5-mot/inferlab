export type LogLevel = 'info' | 'warn' | 'error';

/**
 * credentialを含まないViewer eventをJSON Linesで記録する。
 * @param level log level。
 * @param event event名。
 * @param detail event固有の追加情報。
 * @returns 戻り値はない。
 * @sideeffect 標準出力へログを書き込む。
 */
export function log(
  level: LogLevel,
  event: string,
  detail: Record<string, unknown> = {},
): void {
  process.stdout.write(
    `${JSON.stringify({timestamp: new Date().toISOString(), level, event, ...detail})}\n`,
  );
}
