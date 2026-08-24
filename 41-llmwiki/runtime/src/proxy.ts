import http, {type IncomingHttpHeaders, type Server} from 'node:http';
import type {RuntimeConfig} from './config.js';
import {log} from './logger.js';

export class ViewerProxy {
  readonly #config: RuntimeConfig['viewer'];
  #server: Server | undefined;

  /**
   * upstream viewer専用proxyを生成する。
   * @param config viewerの内部portと公開address。
   * @returns 初期化済みproxy。
   */
  constructor(config: RuntimeConfig['viewer']) {
    this.#config = config;
  }

  /**
   * 公開addressでproxy serverを起動する。
   * @returns listen完了時にresolveするPromise。
   * @throws address bindに失敗した場合。
   * @sideeffect 公開portでHTTP serverをlistenする。
   */
  async start(): Promise<void> {
    if (this.#server) throw new Error('viewer proxyはすでに起動しています');
    const server = http.createServer((request, response) => {
      this.#forward(request, response);
    });
    this.#server = server;
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject);
      server.listen(this.#config.publicPort, this.#config.publicHost, () => resolve());
    });
    log('info', 'viewer.proxy.ready', {
      host: this.#config.publicHost,
      port: this.#config.publicPort,
    });
  }

  /**
   * proxy serverを停止する。
   * @returns 全connection終了時にresolveするPromise。
   * @sideeffect 公開portのlistenを終了する。
   */
  async stop(): Promise<void> {
    const server = this.#server;
    if (!server) return;
    this.#server = undefined;
    await new Promise<void>((resolve, reject) => {
      server.close((error) => error ? reject(error) : resolve());
    });
  }

  /**
   * request headerをloopback viewerのorigin policyへ合わせて転送する。
   * @param request client request。
   * @param response client response。
   * @returns 戻り値はない。
   * @sideeffect upstream viewerへHTTP requestを発行する。
   */
  #forward(request: http.IncomingMessage, response: http.ServerResponse): void {
    const headers = normalizeHeaders(request.headers, this.#config.internalPort);
    const upstream = http.request(
      {
        host: '127.0.0.1',
        port: this.#config.internalPort,
        method: request.method,
        path: request.url,
        headers,
      },
      (upstreamResponse) => {
        response.writeHead(upstreamResponse.statusCode ?? 502, upstreamResponse.headers);
        upstreamResponse.pipe(response);
      },
    );
    upstream.once('error', () => {
      if (response.headersSent) {
        response.destroy();
        return;
      }
      response.writeHead(502, {'content-type': 'application/json; charset=utf-8'});
      response.end(JSON.stringify({error: 'viewer_unavailable'}));
    });
    request.pipe(upstream);
  }
}

/**
 * upstream viewerが許可するHostとOriginへheaderを正規化する。
 * @param headers clientから受信したheader。
 * @param port upstream viewer port。
 * @returns proxy転送用header。
 */
export function normalizeHeaders(
  headers: IncomingHttpHeaders,
  port: number,
): IncomingHttpHeaders {
  const normalized = {...headers, host: `127.0.0.1:${port}`};
  if (normalized.origin) normalized.origin = `http://127.0.0.1:${port}`;
  return normalized;
}
