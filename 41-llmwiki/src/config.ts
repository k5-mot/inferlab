import {readFile} from 'node:fs/promises';
import {load as loadYaml} from 'js-yaml';
import {z} from 'zod';

const ingestSchema = z.strictObject({
  enabled: z.boolean(),
  schedule: z.string().min(1),
  timeout_seconds: z.number().int().positive(),
});

const sourceIngestSchema = ingestSchema.partial().default({});

const inputSourceSchema = z.strictObject({
  id: z.string().min(1).regex(/^[a-z0-9][a-z0-9-]*$/),
  adapter: z.literal('input'),
  input: z.string().min(1),
  ingest: sourceIngestSchema,
});

const couchDbSourceSchema = z.strictObject({
  id: z.string().min(1).regex(/^[a-z0-9][a-z0-9-]*$/),
  adapter: z.literal('couchdb'),
  url: z.string().url(),
  database: z.string().min(1).regex(/^[a-z][a-z0-9_$()+/-]*$/),
  username_env: z.string().min(1).regex(/^[A-Z][A-Z0-9_]*$/),
  password_env: z.string().min(1).regex(/^[A-Z][A-Z0-9_]*$/),
  exclude_path_prefixes: z.array(z.string().min(1)).default([]),
  max_documents: z.number().int().positive().max(10000).default(1000),
  ingest: sourceIngestSchema,
});

const sourceSchema = z.union([inputSourceSchema, couchDbSourceSchema]);

const configSchema = z.strictObject({
  version: z.literal(1),
  project: z.strictObject({root: z.string().min(1)}),
  scheduler: z.strictObject({timezone: z.string().min(1)}),
  defaults: z.strictObject({ingest: ingestSchema}),
  sources: z.array(sourceSchema),
  compile: z.strictObject({
    enabled: z.boolean(),
    schedule: z.string().min(1),
    on_ingest: z.boolean(),
    concurrency: z.number().int().min(1).max(50),
    review: z.boolean(),
    timeout_seconds: z.number().int().positive(),
  }),
  provider: z.strictObject({
    kind: z.literal('openai'),
    model: z.string().min(1),
    base_url: z.string().url(),
    credential_env: z.string().min(1).regex(/^[A-Z][A-Z0-9_]*$/),
    embedding: z.strictObject({
      kind: z.literal('openai'),
      model: z.string().min(1),
      base_url: z.string().url(),
      credential_env: z.string().min(1).regex(/^[A-Z][A-Z0-9_]*$/),
      batch_size: z.number().int().positive(),
      strict: z.boolean(),
    }),
  }),
  output: z.strictObject({language: z.string().min(1)}),
  viewer: z.strictObject({
    internal_port: z.number().int().min(1).max(65535),
    public_host: z.string().min(1),
    public_port: z.number().int().min(1).max(65535),
    startup_timeout_seconds: z.number().int().positive(),
  }),
  validation: z.strictObject({enabled: z.literal(false)}),
});

type ParsedConfig = z.infer<typeof configSchema>;

export interface EffectiveIngestConfig {
  enabled: boolean;
  schedule: string;
  timeoutSeconds: number;
}

interface SourceConfigBase {
  id: string;
  ingest: EffectiveIngestConfig;
}

export interface InputSourceConfig extends SourceConfigBase {
  adapter: 'input';
  input: string;
}

export interface CouchDbSourceConfig extends SourceConfigBase {
  adapter: 'couchdb';
  url: string;
  database: string;
  usernameEnv: string;
  passwordEnv: string;
  excludePathPrefixes: string[];
  maxDocuments: number;
}

export type SourceConfig = InputSourceConfig | CouchDbSourceConfig;

export interface RuntimeConfig {
  projectRoot: string;
  timezone: string;
  sources: SourceConfig[];
  compile: {
    enabled: boolean;
    schedule: string;
    onIngest: boolean;
    concurrency: number;
    review: boolean;
    timeoutSeconds: number;
  };
  provider: {
    kind: 'openai';
    model: string;
    baseUrl: string;
    credentialEnv: string;
    embedding: {
      kind: 'openai';
      model: string;
      baseUrl: string;
      credentialEnv: string;
      batchSize: number;
      strict: boolean;
    };
  };
  outputLanguage: string;
  viewer: {
    internalPort: number;
    publicHost: string;
    publicPort: number;
    startupTimeoutSeconds: number;
  };
}

/**
 * YAML設定を読み込み、未知項目を含めて厳格に検証する。
 * @param configPath 読み込む設定ファイルのpath。
 * @returns source既定値を解決した実行時設定。
 * @throws ファイル読込、YAML parse、schema検証に失敗した場合。
 */
export async function loadConfig(configPath: string): Promise<RuntimeConfig> {
  const source = await readFile(configPath, 'utf8');
  return parseConfig(loadYaml(source));
}

/**
 * 未検証の設定値を実行時設定へ変換する。
 * @param value YAML parserが返した未検証値。
 * @returns source既定値を解決した実行時設定。
 * @throws schema違反がある場合。
 */
export function parseConfig(value: unknown): RuntimeConfig {
  const parsed = configSchema.parse(value);
  assertUniqueSourceIds(parsed.sources);
  return toRuntimeConfig(parsed);
}

/**
 * compile実行時にllmwikiへ渡すprovider環境変数を構築する。
 * @param config 実行時設定。
 * @param environ credentialを参照する環境変数map。
 * @param forceProvider scheduleに関係なくproviderを必須にする場合はtrue。
 * @returns upstream CLI向け環境変数。
 * @throws compileが実行され得る状態でcredentialが未設定の場合。
 */
export function buildProviderEnvironment(
  config: RuntimeConfig,
  environ: NodeJS.ProcessEnv,
  forceProvider = false,
): NodeJS.ProcessEnv {
  const credential = environ[config.provider.credentialEnv];
  const embeddingCredential = environ[config.provider.embedding.credentialEnv];
  const providerRequired = forceProvider || requiresProvider(config);
  if (providerRequired && !credential) {
    throw new Error(`必要なcredential環境変数が未設定です: ${config.provider.credentialEnv}`);
  }
  if (providerRequired && !embeddingCredential) {
    throw new Error(
      `必要なembedding credential環境変数が未設定です: ${config.provider.embedding.credentialEnv}`,
    );
  }
  return {
    ...environ,
    LLMWIKI_PROVIDER: config.provider.kind,
    LLMWIKI_MODEL: config.provider.model,
    LLMWIKI_OUTPUT_LANG: config.outputLanguage,
    OPENAI_BASE_URL: config.provider.baseUrl,
    ...(credential ? {OPENAI_API_KEY: credential} : {}),
    LLMWIKI_EMBEDDING_PROVIDER: config.provider.embedding.kind,
    LLMWIKI_EMBEDDING_MODEL: config.provider.embedding.model,
    LLMWIKI_EMBED_BATCH_SIZE: String(config.provider.embedding.batchSize),
    OPENAI_EMBEDDINGS_BASE_URL: config.provider.embedding.baseUrl,
    ...(embeddingCredential ? {OPENAI_EMBEDDINGS_API_KEY: embeddingCredential} : {}),
    ...(config.provider.embedding.strict ? {LLMWIKI_EMBED_STRICT: 'true'} : {}),
  };
}

/**
 * 有効なCouchDB sourceが参照するcredential環境変数を検証する。
 * @param config 実行時設定。
 * @param environ credentialを参照する環境変数map。
 * @returns 戻り値はない。
 * @throws 有効なCouchDB sourceのcredentialが未設定の場合。
 */
export function validateSourceEnvironment(
  config: RuntimeConfig,
  environ: NodeJS.ProcessEnv,
): void {
  for (const source of config.sources) {
    if (source.adapter !== 'couchdb' || !source.ingest.enabled) continue;
    if (!environ[source.usernameEnv]) {
      throw new Error(`必要なCouchDB username環境変数が未設定です: ${source.usernameEnv}`);
    }
    if (!environ[source.passwordEnv]) {
      throw new Error(`必要なCouchDB password環境変数が未設定です: ${source.passwordEnv}`);
    }
  }
}

/**
 * source IDの重複を検出し、schedule job名の衝突を防ぐ。
 * @param sources 検証済みsource設定。
 * @returns 戻り値はない。
 * @throws 同じIDが複数指定された場合。
 */
function assertUniqueSourceIds(sources: ParsedConfig['sources']): void {
  const ids = new Set<string>();
  for (const source of sources) {
    if (ids.has(source.id)) throw new Error(`source IDが重複しています: ${source.id}`);
    ids.add(source.id);
  }
}

/**
 * schema検証済み設定へsource共通既定値を適用する。
 * @param parsed schema検証済み設定。
 * @returns runnerが利用する正規化済み設定。
 */
function toRuntimeConfig(parsed: ParsedConfig): RuntimeConfig {
  const sources = parsed.sources.map((source): SourceConfig => {
    const ingest = {
      enabled: source.ingest.enabled ?? parsed.defaults.ingest.enabled,
      schedule: source.ingest.schedule ?? parsed.defaults.ingest.schedule,
      timeoutSeconds:
        source.ingest.timeout_seconds ?? parsed.defaults.ingest.timeout_seconds,
    };
    if (source.adapter === 'couchdb') {
      return {
        adapter: 'couchdb',
        id: source.id,
        url: source.url,
        database: source.database,
        usernameEnv: source.username_env,
        passwordEnv: source.password_env,
        excludePathPrefixes: source.exclude_path_prefixes,
        maxDocuments: source.max_documents,
        ingest,
      };
    }
    return {adapter: 'input', id: source.id, input: source.input, ingest};
  });
  return {
    projectRoot: parsed.project.root,
    timezone: parsed.scheduler.timezone,
    sources,
    compile: {
      enabled: parsed.compile.enabled,
      schedule: parsed.compile.schedule,
      onIngest: parsed.compile.on_ingest,
      concurrency: parsed.compile.concurrency,
      review: parsed.compile.review,
      timeoutSeconds: parsed.compile.timeout_seconds,
    },
    provider: {
      kind: parsed.provider.kind,
      model: parsed.provider.model,
      baseUrl: parsed.provider.base_url,
      credentialEnv: parsed.provider.credential_env,
      embedding: {
        kind: parsed.provider.embedding.kind,
        model: parsed.provider.embedding.model,
        baseUrl: parsed.provider.embedding.base_url,
        credentialEnv: parsed.provider.embedding.credential_env,
        batchSize: parsed.provider.embedding.batch_size,
        strict: parsed.provider.embedding.strict,
      },
    },
    outputLanguage: parsed.output.language,
    viewer: {
      internalPort: parsed.viewer.internal_port,
      publicHost: parsed.viewer.public_host,
      publicPort: parsed.viewer.public_port,
      startupTimeoutSeconds: parsed.viewer.startup_timeout_seconds,
    },
  };
}

/**
 * 起動後にproviderを必要とするjobが存在するか判定する。
 * @param config 実行時設定。
 * @returns 定期compileまたはingest後compileが有効ならtrue。
 */
function requiresProvider(config: RuntimeConfig): boolean {
  if (config.compile.enabled) return true;
  return config.compile.onIngest && config.sources.some((source) => source.ingest.enabled);
}
