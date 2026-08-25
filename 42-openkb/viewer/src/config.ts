import {readFile} from 'node:fs/promises';
import {load as loadYaml} from 'js-yaml';
import {z} from 'zod';

const colorSchema = z.string().regex(/^#[0-9a-fA-F]{6}$/);

const configSchema = z.object({
  openkb: z.object({
    generated_wiki_path: z.string().min(1),
  }),
  viewer: z.object({
    workspace_path: z.string().min(1),
    poll_seconds: z.number().positive(),
    startup_timeout_seconds: z.number().positive(),
    mintlify: z.object({
      internal_port: z.number().int().min(1).max(65535),
      public_host: z.string().min(1),
      public_port: z.number().int().min(1).max(65535),
      name: z.string().min(1),
      theme: z.string().min(1),
      colors: z.object({
        primary: colorSchema,
        light: colorSchema,
        dark: colorSchema,
      }),
    }),
  }),
});

export interface ViewerConfig {
  readonly sourcePath: string;
  readonly workspacePath: string;
  readonly pollSeconds: number;
  readonly startupTimeoutSeconds: number;
  readonly mintlify: {
    readonly internalPort: number;
    readonly publicHost: string;
    readonly publicPort: number;
    readonly name: string;
    readonly theme: string;
    readonly colors: {
      readonly primary: string;
      readonly light: string;
      readonly dark: string;
    };
  };
}

/**
 * 共通config.yamlからViewerが所有する設定を読み込む。
 * @param configPath 読み込むYAMLファイルのpath。
 * @returns Viewer用に正規化した設定。
 * @throws ファイル読込、YAML parse、schema検証に失敗した場合。
 */
export async function loadConfig(configPath: string): Promise<ViewerConfig> {
  const source = await readFile(configPath, 'utf8');
  return parseConfig(loadYaml(source));
}

/**
 * 未検証値からViewer設定を抽出する。
 * @param value YAML parserが返した未検証値。
 * @returns Viewer用に正規化した設定。
 * @throws Viewer設定にschema違反がある場合。
 */
export function parseConfig(value: unknown): ViewerConfig {
  const parsed = configSchema.parse(value);
  return {
    sourcePath: parsed.openkb.generated_wiki_path,
    workspacePath: parsed.viewer.workspace_path,
    pollSeconds: parsed.viewer.poll_seconds,
    startupTimeoutSeconds: parsed.viewer.startup_timeout_seconds,
    mintlify: {
      internalPort: parsed.viewer.mintlify.internal_port,
      publicHost: parsed.viewer.mintlify.public_host,
      publicPort: parsed.viewer.mintlify.public_port,
      name: parsed.viewer.mintlify.name,
      theme: parsed.viewer.mintlify.theme,
      colors: parsed.viewer.mintlify.colors,
    },
  };
}
