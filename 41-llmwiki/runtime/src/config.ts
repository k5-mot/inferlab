import {readFile} from 'node:fs/promises';
import {load as loadYaml} from 'js-yaml';
import {z} from 'zod';

const providerSchema = z.strictObject({
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
});

const configSchema = z.strictObject({
  version: z.literal(1),
  project: z.strictObject({root: z.string().min(1)}),
  provider: providerSchema,
  output: z.strictObject({language: z.string().min(1)}),
  runtime: z.strictObject({
    viewer: z.strictObject({
      internal_port: z.number().int().min(1).max(65535),
      public_host: z.string().min(1),
      public_port: z.number().int().min(1).max(65535),
      startup_timeout_seconds: z.number().int().positive(),
      reload_poll_seconds: z.number().positive(),
    }),
  }),
  ingester: z.unknown(),
});

export interface RuntimeConfig {
  projectRoot: string;
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
    reloadPollSeconds: number;
  };
}

/**
 * Runtimeが所有する設定だけをYAMLから読み込む。
 * @param configPath 読み込む設定ファイルのpath。
 * @returns ViewerとMCP用に正規化した設定。
 * @throws file読込、YAML parse、Runtime schema検証に失敗した場合。
 */
export async function loadConfig(configPath: string): Promise<RuntimeConfig> {
  const source = await readFile(configPath, 'utf8');
  return parseConfig(loadYaml(source));
}

/**
 * 未検証値からRuntime設定を抽出する。
 * @param value YAML parserが返した未検証値。
 * @returns ViewerとMCP用に正規化した設定。
 * @throws Runtimeが所有する設定にschema違反がある場合。
 */
export function parseConfig(value: unknown): RuntimeConfig {
  const parsed = configSchema.parse(value);
  return {
    projectRoot: parsed.project.root,
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
      internalPort: parsed.runtime.viewer.internal_port,
      publicHost: parsed.runtime.viewer.public_host,
      publicPort: parsed.runtime.viewer.public_port,
      startupTimeoutSeconds: parsed.runtime.viewer.startup_timeout_seconds,
      reloadPollSeconds: parsed.runtime.viewer.reload_poll_seconds,
    },
  };
}

/**
 * Runtimeのupstream CLIへ渡すprovider環境変数を構築する。
 * @param config Runtime設定。
 * @param environ credentialを参照する環境変数map。
 * @param requireCredential MCP利用時にcredentialを必須とする場合はtrue。
 * @returns upstream CLI向け環境変数。
 * @throws 必須credentialが未設定の場合。
 */
export function buildProviderEnvironment(
  config: RuntimeConfig,
  environ: NodeJS.ProcessEnv,
  requireCredential = false,
): NodeJS.ProcessEnv {
  const credential = environ[config.provider.credentialEnv];
  const embeddingCredential = environ[config.provider.embedding.credentialEnv];
  if (requireCredential && !credential) {
    throw new Error(`必要なcredential環境変数が未設定です: ${config.provider.credentialEnv}`);
  }
  if (requireCredential && !embeddingCredential) {
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
