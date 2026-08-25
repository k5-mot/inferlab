import http, {
  type IncomingHttpHeaders,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import type {ViewerConfig} from './config.js';
import {log} from './logger.js';

/** 公開portとloopback Mintlify previewの間を中継する。 */
export class ViewerProxy {
  readonly #config: ViewerConfig['mintlify'];
  readonly #workspacePath: string;
  readonly #staticPath: string;
  #server: Server | undefined;

  /**
   * Viewer proxyを生成する。
   * @param config 内部portと公開addressを含むMintlify設定。
   * @param workspacePath 動的Graph dataを格納するMintlify workspace。
   * @param staticPath Graph UI assetを格納するimage内directory。
   * @returns 初期化済みproxy。
   */
  constructor(
    config: ViewerConfig['mintlify'],
    workspacePath: string,
    staticPath: string,
  ) {
    this.#config = config;
    this.#workspacePath = workspacePath;
    this.#staticPath = staticPath;
  }

  /**
   * 公開addressでproxyを起動する。
   * @returns listen完了時にresolveするPromise。
   * @throws address bindに失敗した場合。
   * @sideeffect HTTP serverを起動する。
   */
  async start(): Promise<void> {
    if (this.#server) throw new Error('Viewer proxyはすでに起動しています');
    const server = http.createServer((request, response) => {
      if (request.url === '/health') {
        void this.#serveHealth(response);
        return;
      }
      if (request.url?.startsWith('/openkb-graph/')) {
        void this.#serveGraphAsset(request, response);
        return;
      }
      this.#forward(request, response);
    });
    this.#server = server;
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject);
      server.listen(this.#config.publicPort, this.#config.publicHost, resolve);
    });
    log('info', 'viewer.proxy.ready', {
      host: this.#config.publicHost,
      port: this.#config.publicPort,
    });
  }

  /**
   * Mintlify previewを含むViewer全体のhealthを返す。
   * @param response client response。
   * @returns health確認と応答完了時にresolveするPromise。
   * @sideeffect loopback MintlifyへHTTP requestを発行する。
   */
  async #serveHealth(response: ServerResponse): Promise<void> {
    try {
      const upstream = await fetch(`http://127.0.0.1:${this.#config.internalPort}/`, {
        signal: AbortSignal.timeout(1000),
      });
      const healthy = upstream.ok;
      response.writeHead(healthy ? 200 : 503, {
        'content-type': 'application/json; charset=utf-8',
      });
      response.end(JSON.stringify({status: healthy ? 'ok' : 'unavailable'}));
    } catch {
      response.writeHead(503, {'content-type': 'application/json; charset=utf-8'});
      response.end(JSON.stringify({status: 'unavailable'}));
    }
  }

  /**
   * 公開proxyを停止する。
   * @returns 全connection終了時にresolveするPromise。
   * @sideeffect HTTP serverのlistenを終了する。
   */
  async stop(): Promise<void> {
    const server = this.#server;
    if (!server) return;
    this.#server = undefined;
    await new Promise<void>((resolve, reject) => {
      server.close((error) => (error ? reject(error) : resolve()));
    });
  }

  /**
   * allowlist済みGraph assetをMintlifyを経由せず配信する。
   * @param request client request。
   * @param response client response。
   * @returns asset配信完了時にresolveするPromise。
   * @sideeffect image内static fileまたはworkspace dataをHTTP responseへ書き込む。
   */
  async #serveGraphAsset(
    request: IncomingMessage,
    response: ServerResponse,
  ): Promise<void> {
    const assetName = request.url?.slice('/openkb-graph/'.length).split('?', 1)[0];
    const assets: Record<string, {filePath: string; contentType: string}> = {
      'index.html': {
        filePath: path.join(this.#staticPath, 'graph', 'index.html'),
        contentType: 'text/html; charset=utf-8',
      },
      'graph.css': {
        filePath: path.join(this.#staticPath, 'graph', 'graph.css'),
        contentType: 'text/css; charset=utf-8',
      },
      'graph.js': {
        filePath: path.join(this.#staticPath, 'graph', 'graph.js'),
        contentType: 'application/javascript; charset=utf-8',
      },
      'graph-data.js': {
        filePath: path.join(this.#workspacePath, 'viewer-data', 'graph-data.js'),
        contentType: 'application/javascript; charset=utf-8',
      },
    };
    const asset = assetName ? assets[assetName] : undefined;
    if (!asset) {
      response.writeHead(404, {'content-type': 'text/plain; charset=utf-8'});
      response.end('Not Found');
      return;
    }
    try {
      const content = await readFile(asset.filePath);
      response.writeHead(200, {
        'content-type': asset.contentType,
        'cache-control': 'no-store',
        'content-length': content.byteLength,
      });
      if (request.method === 'HEAD') response.end();
      else response.end(content);
    } catch (error) {
      log('error', 'viewer.graph_asset.failed', {
        asset: assetName,
        error: error instanceof Error ? error.message : String(error),
      });
      response.writeHead(500, {'content-type': 'text/plain; charset=utf-8'});
      response.end('Graph asset unavailable');
    }
  }

  /**
   * client requestをMintlify previewへ転送する。
   * @param request client request。
   * @param response client response。
   * @returns 戻り値はない。
   * @sideeffect loopback MintlifyへHTTP requestを発行する。
   */
  #forward(request: IncomingMessage, response: ServerResponse): void {
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
      response.end(JSON.stringify({error: 'mintlify_unavailable'}));
    });
    request.pipe(upstream);
  }
}

/**
 * upstream previewが受理できるHostとOriginへheaderを正規化する。
 * @param headers client request header。
 * @param port Mintlify内部port。
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
