import type {CouchDbSourceConfig, InputSourceConfig, SourceConfig} from './config.js';
import {synchronizeCouchDbSource} from './couchdb-source.js';

export interface SourceAdapterContext {
  projectRoot: string;
  environment: NodeJS.ProcessEnv;
}

export interface SourceAdapter {
  readonly kind: SourceConfig['adapter'];
  synchronize(source: SourceConfig, context: SourceAdapterContext): Promise<void>;
}

export interface InputCommand {
  args: string[];
  timeoutSeconds: number;
}

type InputCommandRunner = (command: InputCommand) => Promise<void>;
type FetchLike = typeof fetch;

/** source種別と具体的な同期処理の対応を一か所で管理するregistry。 */
export class SourceAdapterRegistry {
  readonly #adapters: ReadonlyMap<SourceConfig['adapter'], SourceAdapter>;

  /**
   * source adapter registryを生成する。
   * @param adapters 利用可能なsource adapter。
   * @returns 初期化済みregistry instance。
   * @throws 同じkindのadapterが重複している場合。
   */
  constructor(adapters: SourceAdapter[]) {
    const byKind = new Map<SourceConfig['adapter'], SourceAdapter>();
    for (const adapter of adapters) {
      if (byKind.has(adapter.kind)) {
        throw new Error(`source adapterが重複しています: ${adapter.kind}`);
      }
      byKind.set(adapter.kind, adapter);
    }
    this.#adapters = byKind;
  }

  /**
   * sourceに対応するadapterを選び、同期を実行する。
   * @param source 同期する正規化済みsource設定。
   * @param context project rootとcredential環境変数。
   * @returns 同期完了時にresolveするPromise。
   * @throws 対応adapterがない、またはadapterの同期に失敗した場合。
   * @sideeffect adapterに応じてsource fileまたは外部接続を更新する。
   */
  async synchronize(source: SourceConfig, context: SourceAdapterContext): Promise<void> {
    const adapter = this.#adapters.get(source.adapter);
    if (!adapter) throw new Error(`source adapterが見つかりません: ${source.adapter}`);
    await adapter.synchronize(source, context);
  }
}

/**
 * 現在対応するすべてのsource adapterを組み立てる。
 * @param runInputCommand upstream CLIを実行する関数。
 * @param fetchImpl CouchDB取得に使用するFetch実装。
 * @returns inputとCouchDBに対応するregistry。
 */
export function createSourceAdapterRegistry(
  runInputCommand: InputCommandRunner,
  fetchImpl: FetchLike = fetch,
): SourceAdapterRegistry {
  return new SourceAdapterRegistry([
    new InputSourceAdapter(runInputCommand),
    new CouchDbSourceAdapter(fetchImpl),
  ]);
}

class InputSourceAdapter implements SourceAdapter {
  readonly kind = 'input' as const;
  readonly #runCommand: InputCommandRunner;

  /**
   * upstream CLIを利用するinput adapterを生成する。
   * @param runCommand timeout管理を含むCLI実行関数。
   * @returns 初期化済みadapter instance。
   */
  constructor(runCommand: InputCommandRunner) {
    this.#runCommand = runCommand;
  }

  /**
   * URLまたはfile inputをupstream CLIへ渡す。
   * @param source 同期対象のsource設定。
   * @param context 共通adapter context。input adapterでは使用しない。
   * @returns CLI終了時にresolveするPromise。
   * @throws source kindが異なる、またはCLI実行に失敗した場合。
   * @sideeffect project rootのsourcesをupstream CLI経由で更新する。
   */
  async synchronize(source: SourceConfig, context: SourceAdapterContext): Promise<void> {
    void context;
    const inputSource = requireInputSource(source);
    await this.#runCommand({
      args: ['ingest', inputSource.input],
      timeoutSeconds: inputSource.ingest.timeoutSeconds,
    });
  }
}

class CouchDbSourceAdapter implements SourceAdapter {
  readonly kind = 'couchdb' as const;
  readonly #fetch: FetchLike;

  /**
   * LiveSync snapshotを利用するCouchDB adapterを生成する。
   * @param fetchImpl CouchDB取得に使用するFetch実装。
   * @returns 初期化済みadapter instance。
   */
  constructor(fetchImpl: FetchLike) {
    this.#fetch = fetchImpl;
  }

  /**
   * CouchDB snapshotをLLMWiki sourceへ同期する。
   * @param source 同期対象のsource設定。
   * @param context project rootとcredential環境変数。
   * @returns 同期終了時にresolveするPromise。
   * @throws source kindが異なる、またはCouchDB同期に失敗した場合。
   * @sideeffect project rootのsourcesと同期manifestを更新する。
   */
  async synchronize(source: SourceConfig, context: SourceAdapterContext): Promise<void> {
    await synchronizeCouchDbSource(
      context.projectRoot,
      requireCouchDbSource(source),
      context.environment,
      this.#fetch,
    );
  }
}

/**
 * source設定をinput種別へ絞り込む。
 * @param source 絞り込むsource設定。
 * @returns input source設定。
 * @throws source kindがinputでない場合。
 */
function requireInputSource(source: SourceConfig): InputSourceConfig {
  if (source.adapter !== 'input') {
    throw new Error(`input adapterへ不正なsourceが渡されました: ${source.adapter}`);
  }
  return source;
}

/**
 * source設定をCouchDB種別へ絞り込む。
 * @param source 絞り込むsource設定。
 * @returns CouchDB source設定。
 * @throws source kindがcouchdbでない場合。
 */
function requireCouchDbSource(source: SourceConfig): CouchDbSourceConfig {
  if (source.adapter !== 'couchdb') {
    throw new Error(`CouchDB adapterへ不正なsourceが渡されました: ${source.adapter}`);
  }
  return source;
}
