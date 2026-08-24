import {mkdir, readFile, rename, unlink, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {createWiki, type WriteStatus} from 'llm-wiki-compiler';
import type {CouchDbSourceConfig} from './config.js';
import {log} from './logger.js';

export interface CouchDbSourceDocument {
  id: string;
  path: string;
  content: string;
}

export interface CouchDbSyncSummary {
  documents: number;
  created: number;
  updated: number;
  unchanged: number;
  removed: number;
  skippedEmpty: number;
}

type FetchLike = typeof fetch;
type SourceManifest = Record<string, string>;

/**
 * CouchDBのLiveSync snapshotをLLMWiki sourceへ同期する。
 * @param projectRoot LLMWiki project root。
 * @param source CouchDB接続設定。
 * @param environ credentialを参照する環境変数map。
 * @param fetchImpl test時に差し替え可能なFetch実装。
 * @returns 取得・更新・削除件数。
 * @throws CouchDB取得、LiveSync chunk復元、source書込に失敗した場合。
 * @sideeffect project rootのsourcesとmanifestを更新する。
 */
export async function synchronizeCouchDbSource(
  projectRoot: string,
  source: CouchDbSourceConfig,
  environ: NodeJS.ProcessEnv,
  fetchImpl: FetchLike = fetch,
): Promise<CouchDbSyncSummary> {
  const documents = await fetchCouchDbDocuments(source, environ, fetchImpl);
  const wiki = createWiki({root: projectRoot});
  const previousManifest = await readManifest(projectRoot, source.id);
  const nextManifest: SourceManifest = {};
  const statuses: Record<WriteStatus, number> = {created: 0, updated: 0, unchanged: 0};
  let skippedEmpty = 0;

  for (const document of documents) {
    if (document.content.trim().length === 0) {
      skippedEmpty += 1;
      continue;
    }
    const result = await wiki.ingestText({
      title: document.path,
      text: document.content,
      source: couchDbDocumentUrl(source, document.id),
    });
    statuses[result.writeStatus] = (statuses[result.writeStatus] ?? 0) + 1;
    nextManifest[document.id] = result.filename;
  }

  const removed = await removeStaleSources(projectRoot, previousManifest, nextManifest);
  await writeManifest(projectRoot, source.id, nextManifest);
  const summary = {
    documents: documents.length,
    created: statuses.created,
    updated: statuses.updated,
    unchanged: statuses.unchanged,
    removed,
    skippedEmpty,
  };
  log('info', 'couchdb.source.synchronized', {source: source.id, ...summary});
  return summary;
}

/**
 * CouchDBの`_all_docs`からLiveSync Markdown documentを復元する。
 * @param source CouchDB接続設定。
 * @param environ credentialを参照する環境変数map。
 * @param fetchImpl HTTP取得に使用するFetch実装。
 * @returns path順に並べた復元済みMarkdown document。
 * @throws credential、HTTP応答、JSON構造、chunk参照が不正な場合。
 */
export async function fetchCouchDbDocuments(
  source: CouchDbSourceConfig,
  environ: NodeJS.ProcessEnv,
  fetchImpl: FetchLike = fetch,
): Promise<CouchDbSourceDocument[]> {
  const username = environ[source.usernameEnv];
  const password = environ[source.passwordEnv];
  if (!username) throw new Error(`CouchDB usernameが未設定です: ${source.usernameEnv}`);
  if (!password) throw new Error(`CouchDB passwordが未設定です: ${source.passwordEnv}`);

  const endpoint = couchDbAllDocsUrl(source);
  const response = await fetchImpl(endpoint, {
    headers: {
      accept: 'application/json',
      authorization: `Basic ${Buffer.from(`${username}:${password}`).toString('base64')}`,
    },
    signal: AbortSignal.timeout(source.ingest.timeoutSeconds * 1000),
  });
  if (!response.ok) {
    throw new Error(`CouchDB snapshot取得に失敗しました: status=${response.status}`);
  }
  const payload: unknown = await response.json();
  const rows = allDocsRows(payload);
  const documentsById = new Map<string, Record<string, unknown>>();
  for (const row of rows) {
    const document = recordValue(row.doc);
    const id = stringValue(document?._id);
    if (document && id) documentsById.set(id, document);
  }

  const parents = [...documentsById.values()].filter(
    (document) => isVisibleMarkdownParent(document, source.excludePathPrefixes),
  );
  if (parents.length > source.maxDocuments) {
    throw new Error(
      `CouchDB Markdown document数が上限を超えています: ${parents.length}/${source.maxDocuments}`,
    );
  }
  return parents.map((parent) => restoreDocument(parent, documentsById))
    .sort((left, right) => left.path.localeCompare(right.path));
}

/**
 * CouchDB URLへdatabase document pathを付与する。
 * @param source CouchDB接続設定。
 * @param documentId URLへ含めるdocument ID。
 * @returns credentialを含まないdocument URL。
 */
function couchDbDocumentUrl(source: CouchDbSourceConfig, documentId: string): string {
  const baseUrl = normalizedBaseUrl(source.url);
  return new URL(
    `${encodeURIComponent(source.database)}/${encodeURIComponent(documentId)}`,
    baseUrl,
  ).toString();
}

/**
 * CouchDB URLへ`_all_docs` endpointとqueryを付与する。
 * @param source CouchDB接続設定。
 * @returns `include_docs=true`を指定したendpoint URL。
 */
function couchDbAllDocsUrl(source: CouchDbSourceConfig): URL {
  const endpoint = new URL(
    `${encodeURIComponent(source.database)}/_all_docs`,
    normalizedBaseUrl(source.url),
  );
  endpoint.searchParams.set('include_docs', 'true');
  return endpoint;
}

/**
 * credentialを含まない末尾slash付きCouchDB base URLを返す。
 * @param value 設定から受け取ったCouchDB URL。
 * @returns 相対pathを安全に解決できるbase URL。
 * @throws URLへcredentialが埋め込まれている場合。
 */
function normalizedBaseUrl(value: string): URL {
  const baseUrl = new URL(value.endsWith('/') ? value : `${value}/`);
  if (baseUrl.username || baseUrl.password) {
    throw new Error('CouchDB URLへcredentialを埋め込んではなりません');
  }
  return baseUrl;
}

/**
 * `_all_docs`応答からrow配列を検証して返す。
 * @param value CouchDBから受け取った未検証JSON値。
 * @returns objectであることを検証したrow配列。
 * @throws rowsが存在しない、またはrowがobjectでない場合。
 */
function allDocsRows(value: unknown): Array<Record<string, unknown>> {
  const payload = recordValue(value);
  if (!payload || !Array.isArray(payload.rows)) {
    throw new Error('CouchDB `_all_docs`応答にrowsがありません');
  }
  return payload.rows.map((row) => {
    const record = recordValue(row);
    if (!record) throw new Error('CouchDB `_all_docs` rowがobjectではありません');
    return record;
  });
}

/**
 * LiveSync親documentが公開Markdown noteであるか判定する。
 * @param document 判定するCouchDB document。
 * @param excludePathPrefixes adapter設定で除外するpath prefix。
 * @returns 非削除かつhidden pathでないMarkdown親documentならtrue。
 */
function isVisibleMarkdownParent(
  document: Record<string, unknown>,
  excludePathPrefixes: readonly string[],
): boolean {
  if (document.type !== 'plain' || document.deleted === true) return false;
  const notePath = stringValue(document.path);
  if (!notePath || !notePath.toLowerCase().endsWith('.md')) return false;
  if (excludePathPrefixes.some((prefix) => notePath.startsWith(prefix))) return false;
  return !notePath.split('/').some((segment) => segment.startsWith('.'));
}

/**
 * LiveSync親documentと順序付きleaf chunkからMarkdown本文を復元する。
 * @param parent 復元対象のLiveSync親document。
 * @param documentsById leaf chunkを検索するdocument map。
 * @returns ID、path、復元本文を持つMarkdown document。
 * @throws 親documentまたは参照先leaf chunkの構造が不正な場合。
 */
function restoreDocument(
  parent: Record<string, unknown>,
  documentsById: ReadonlyMap<string, Record<string, unknown>>,
): CouchDbSourceDocument {
  const id = requiredString(parent._id, '親documentの_id');
  const notePath = requiredString(parent.path, `親document ${id} のpath`);
  if (!Array.isArray(parent.children)) {
    throw new Error(`LiveSync親documentにchildrenがありません: ${id}`);
  }
  const chunks = parent.children.map((childIdValue) => {
    const childId = requiredString(childIdValue, `親document ${id} のchild ID`);
    const child = documentsById.get(childId);
    if (!child || child.type !== 'leaf') {
      throw new Error(`LiveSync leaf chunkが見つかりません: ${childId}`);
    }
    return requiredString(child.data, `LiveSync leaf chunk ${childId} のdata`);
  });
  return {id, path: notePath, content: chunks.join('')};
}

/**
 * 前回manifestにだけ存在するLLMWiki source fileを削除する。
 * @param projectRoot LLMWiki project root。
 * @param previous 前回同期時のdocument IDとfile名の対応。
 * @param next 今回同期時のdocument IDとfile名の対応。
 * @returns 削除したsource file数。
 * @throws file削除が未存在以外の理由で失敗した場合。
 * @sideeffect project rootのsourcesから古いfileを削除する。
 */
async function removeStaleSources(
  projectRoot: string,
  previous: SourceManifest,
  next: SourceManifest,
): Promise<number> {
  const retained = new Set(Object.values(next));
  let removed = 0;
  for (const filename of new Set(Object.values(previous))) {
    if (retained.has(filename) || !isSafeSourceFilename(filename)) continue;
    try {
      await unlink(path.join(projectRoot, 'sources', filename));
      removed += 1;
    } catch (error) {
      if (!isFileNotFound(error)) throw error;
    }
  }
  return removed;
}

/**
 * source file名がsources直下のMarkdownだけを指すことを検証する。
 * @param filename manifestへ記録されたsource file名。
 * @returns sources直下のMarkdown fileだけを指すならtrue。
 */
function isSafeSourceFilename(filename: string): boolean {
  return path.basename(filename) === filename && filename.endsWith('.md');
}

/**
 * CouchDB source manifestを読み、初回または欠損時は空objectを返す。
 * @param projectRoot LLMWiki project root。
 * @param sourceId manifestを識別するsource ID。
 * @returns document IDとsource file名の対応。
 * @throws manifestのJSONまたはfile名が不正な場合。
 */
async function readManifest(projectRoot: string, sourceId: string): Promise<SourceManifest> {
  try {
    const value: unknown = JSON.parse(await readFile(manifestPath(projectRoot, sourceId), 'utf8'));
    const record = recordValue(value);
    if (!record) throw new Error(`CouchDB source manifestがobjectではありません: ${sourceId}`);
    const manifest: SourceManifest = {};
    for (const [id, filename] of Object.entries(record)) {
      if (typeof filename !== 'string' || !isSafeSourceFilename(filename)) {
        throw new Error(`CouchDB source manifestのfile名が不正です: ${sourceId}`);
      }
      manifest[id] = filename;
    }
    return manifest;
  } catch (error) {
    if (isFileNotFound(error)) return {};
    throw error;
  }
}

/**
 * CouchDB source manifestを一時file経由で置換する。
 * @param projectRoot LLMWiki project root。
 * @param sourceId manifestを識別するsource ID。
 * @param manifest 保存するdocument IDとsource file名の対応。
 * @returns 書込完了時にresolveするPromise。
 * @sideeffect project rootの.llmwikiへmanifestを書き込む。
 */
async function writeManifest(
  projectRoot: string,
  sourceId: string,
  manifest: SourceManifest,
): Promise<void> {
  const directory = path.join(projectRoot, '.llmwiki');
  const target = manifestPath(projectRoot, sourceId);
  const temporary = `${target}.${process.pid}.tmp`;
  await mkdir(directory, {recursive: true});
  await writeFile(temporary, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
  await rename(temporary, target);
}

/**
 * source IDに対応するmanifest pathを返す。
 * @param projectRoot LLMWiki project root。
 * @param sourceId manifestを識別するsource ID。
 * @returns manifestの絶対path。
 */
function manifestPath(projectRoot: string, sourceId: string): string {
  return path.join(projectRoot, '.llmwiki', `couchdb-source-${sourceId}.json`);
}

/**
 * unknown値をplain objectへ絞り込む。
 * @param value 絞り込む未検証値。
 * @returns plain objectならその値、それ以外はundefined。
 */
function recordValue(value: unknown): Record<string, unknown> | undefined {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return undefined;
  return value as Record<string, unknown>;
}

/**
 * unknown値がstringなら返す。
 * @param value 絞り込む未検証値。
 * @returns stringならその値、それ以外はundefined。
 */
function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

/**
 * unknown値が空でないstringであることを検証する。
 * @param value 検証する未検証値。
 * @param field errorに含めるfield名。
 * @returns 空でないstring値。
 * @throws 値が空またはstringでない場合。
 */
function requiredString(value: unknown, field: string): string {
  const text = stringValue(value);
  if (!text) throw new Error(`${field}が空またはstringではありません`);
  return text;
}

/**
 * filesystem errorがfile未存在を表すか判定する。
 * @param error filesystem APIから受け取った値。
 * @returns error codeがENOENTならtrue。
 */
function isFileNotFound(error: unknown): boolean {
  return error instanceof Error && 'code' in error && error.code === 'ENOENT';
}
