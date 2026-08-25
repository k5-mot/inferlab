import {createHash} from 'node:crypto';
import {
  mkdir,
  readFile,
  readdir,
  rename,
  rm,
  stat,
  writeFile,
} from 'node:fs/promises';
import path from 'node:path';
import matter from 'gray-matter';
import type {ViewerConfig} from './config.js';

const WIKILINK_PATTERN = /\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|([^\]]+))?\]\]/g;
const MARKDOWN_LINK_PATTERN = /\[([^\]]+)]\(([^)]+)\)/g;
const EXCLUDED_DIRECTORIES = new Set(['raw', 'reports']);

interface SourcePage {
  readonly id: string;
  readonly relativePath: string;
  readonly title: string;
  readonly description: string;
  readonly category: string;
  readonly body: string;
  readonly outputPath: string;
  readonly url: string;
}

interface GraphNode {
  readonly data: {
    readonly id: string;
    readonly label: string;
    readonly category: string;
    readonly description: string;
    readonly url: string;
  };
}

interface GraphEdge {
  readonly data: {
    readonly id: string;
    readonly source: string;
    readonly target: string;
  };
}

interface NavigationGroup {
  readonly group: string;
  readonly pages: Array<string | NavigationGroup>;
  readonly expanded?: boolean;
}

export interface ContentSnapshot {
  readonly digest: string;
  readonly pageCount: number;
  readonly edgeCount: number;
}

/**
 * OpenKB生成物の内容hashを計算する。
 * @param sourcePath read-only mountされたGenerated Wikiのpath。
 * @returns 相対pathと内容から作る安定したdigest。
 * @throws directory走査またはファイル読込に失敗した場合。
 */
export async function computeSourceDigest(sourcePath: string): Promise<string> {
  const files = await listMarkdownFiles(sourcePath);
  const hash = createHash('sha256');
  for (const filePath of files) {
    hash.update(path.relative(sourcePath, filePath));
    hash.update('\0');
    hash.update(await readFile(filePath));
    hash.update('\0');
  }
  return hash.digest('hex');
}

/**
 * OpenKB MarkdownからMintlify workspaceを原子的に再生成する。
 * @param config source、workspace、brandingを含むViewer設定。
 * @returns 生成したpage数、edge数、source digest。
 * @throws Markdown parseまたはworkspace更新に失敗した場合。
 * @sideeffect workspacePathの内容を新しい世代へ置き換える。
 */
export async function synchronizeContent(
  config: ViewerConfig,
): Promise<ContentSnapshot> {
  const pages = await loadSourcePages(config.sourcePath);
  const aliases = buildAliases(pages);
  const graph = buildGraph(pages, aliases);
  const digest = await computeSourceDigest(config.sourcePath);
  const stagingPath = `${config.workspacePath}.next`;

  await rm(stagingPath, {recursive: true, force: true});
  await mkdir(stagingPath, {recursive: true});
  await writeGeneratedPages(stagingPath, pages, aliases);
  await writeViewerPages(stagingPath, pages.length);
  await mkdir(path.join(stagingPath, 'viewer-data'), {recursive: true});
  await writeFile(
    path.join(stagingPath, 'viewer-data', 'graph-data.js'),
    `window.__OPENKB_GRAPH__ = ${serializeForScript(graph)};\n`,
    'utf8',
  );
  await writeFile(
    path.join(stagingPath, 'docs.json'),
    `${JSON.stringify(buildDocsConfig(config, pages), null, 2)}\n`,
    'utf8',
  );

  await rm(config.workspacePath, {recursive: true, force: true});
  await rename(stagingPath, config.workspacePath);
  return {digest, pageCount: pages.length, edgeCount: graph.edges.length};
}

/**
 * JSON dataをscript element内でも閉じタグとして解釈されない形へ変換する。
 * @param value JSON serializeするgraph data。
 * @returns JavaScriptへ安全に埋め込めるJSON文字列。
 */
function serializeForScript(value: unknown): string {
  return JSON.stringify(value)
    .replace(/</g, '\\u003c')
    .replace(/\u2028/g, '\\u2028')
    .replace(/\u2029/g, '\\u2029');
}

/**
 * source directory配下の公開対象Markdownを再帰的に列挙する。
 * @param sourcePath Generated Wiki directory。
 * @returns 相対path順のMarkdown絶対path一覧。directory未作成時は空配列。
 * @throws directory走査に失敗した場合。
 */
async function listMarkdownFiles(sourcePath: string): Promise<string[]> {
  try {
    if (!(await stat(sourcePath)).isDirectory()) return [];
  } catch (error) {
    if (isMissingFileError(error)) return [];
    throw error;
  }

  const files: string[] = [];
  /**
   * 1 directoryを走査して公開対象Markdownを蓄積する。
   * @param directory 現在走査する絶対path。
   * @param depth source rootからのdirectory深さ。
   * @returns 走査完了時にresolveするPromise。
   * @throws directory読込に失敗した場合。
   */
  async function visit(directory: string, depth: number): Promise<void> {
    const entries = await readdir(directory, {withFileTypes: true});
    for (const entry of entries) {
      if (entry.isDirectory() && depth === 0 && EXCLUDED_DIRECTORIES.has(entry.name)) {
        continue;
      }
      const entryPath = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        await visit(entryPath, depth + 1);
      } else if (entry.isFile() && /\.mdx?$/i.test(entry.name)) {
        files.push(entryPath);
      }
    }
  }
  await visit(sourcePath, 0);
  return files.sort((left, right) => left.localeCompare(right));
}

/**
 * MarkdownファイルをViewer内部表現へ変換する。
 * @param sourcePath Generated Wiki directory。
 * @returns title、URL、本文を持つpage一覧。
 * @throws Markdown読込またはfrontmatter parseに失敗した場合。
 */
async function loadSourcePages(sourcePath: string): Promise<SourcePage[]> {
  const files = await listMarkdownFiles(sourcePath);
  const pages: SourcePage[] = [];
  for (const filePath of files) {
    const relativePath = path.relative(sourcePath, filePath).split(path.sep).join('/');
    const parsed = matter(await readFile(filePath, 'utf8'));
    const body = parsed.content;
    const id = relativePath.replace(/\.mdx?$/i, '');
    const title = readString(parsed.data.title) ?? firstHeading(body) ?? path.parse(filePath).name;
    const description = readString(parsed.data.description) ?? '';
    const category = relativePath.includes('/') ? relativePath.split('/')[0] ?? 'Wiki' : 'Wiki';
    const outputPath = `wiki/${id}.mdx`;
    pages.push({
      id,
      relativePath,
      title,
      description,
      category,
      body,
      outputPath,
      url: `/${outputPath.replace(/\.mdx$/, '')}`,
    });
  }
  return pages;
}

/**
 * frontmatter値をtrim済み文字列として取得する。
 * @param value frontmatter由来の未検証値。
 * @returns 空でない文字列、またはundefined。
 */
function readString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined;
}

/**
 * Markdown本文の最初のH1を抽出する。
 * @param body frontmatterを除いたMarkdown本文。
 * @returns H1 text、または存在しない場合undefined。
 */
function firstHeading(body: string): string | undefined {
  return body
    .split('\n')
    .find((line) => line.startsWith('# '))
    ?.slice(2)
    .trim();
}

/**
 * Wiki link解決に使うalias mapを構築する。
 * @param pages 全Source Page。
 * @returns 正規化aliasからpageへの対応。
 */
function buildAliases(pages: readonly SourcePage[]): Map<string, SourcePage> {
  const aliases = new Map<string, SourcePage>();
  for (const page of pages) {
    const baseName = page.id.split('/').at(-1) ?? page.id;
    for (const alias of [page.id, baseName, page.title]) {
      const normalized = normalizeTarget(alias);
      if (!aliases.has(normalized)) aliases.set(normalized, page);
    }
  }
  return aliases;
}

/**
 * link targetを大文字小文字や区切り差を無視できるkeyへ変換する。
 * @param target Wiki linkまたはMarkdown linkのtarget。
 * @returns alias検索用key。
 */
function normalizeTarget(target: string): string {
  return decodeURIComponent(target)
    .replace(/^[./]+/, '')
    .replace(/\.mdx?$/i, '')
    .replace(/[ _-]+/g, '')
    .toLocaleLowerCase();
}

/**
 * page本文の内部Wiki linkをMintlify page linkへ変換する。
 * @param body 変換前Markdown本文。
 * @param aliases link解決用alias map。
 * @returns link変換後のMarkdown本文。
 */
function rewriteLinks(body: string, aliases: ReadonlyMap<string, SourcePage>): string {
  const withWikiLinks = body.replace(
    WIKILINK_PATTERN,
    (original: string, target: string, label: string | undefined) => {
      const page = aliases.get(normalizeTarget(target));
      return page ? `[${label?.trim() || target.trim()}](${page.url})` : original;
    },
  );
  return withWikiLinks.replace(
    MARKDOWN_LINK_PATTERN,
    (original: string, label: string, target: string) => {
      const [pathname, fragment] = target.split('#', 2);
      if (!pathname || !/\.mdx?$/i.test(pathname)) return original;
      const page = aliases.get(normalizeTarget(pathname));
      return page ? `[${label}](${page.url}${fragment ? `#${fragment}` : ''})` : original;
    },
  );
}

/**
 * Generated Wiki pageをMintlify用MDXとして書き込む。
 * @param workspacePath staging workspace。
 * @param pages 書き込むSource Page一覧。
 * @param aliases link解決用alias map。
 * @returns 全page書込完了時にresolveするPromise。
 * @sideeffect workspace配下へMDXを作成する。
 */
async function writeGeneratedPages(
  workspacePath: string,
  pages: readonly SourcePage[],
  aliases: ReadonlyMap<string, SourcePage>,
): Promise<void> {
  for (const page of pages) {
    const destination = path.join(workspacePath, page.outputPath);
    await mkdir(path.dirname(destination), {recursive: true});
    const frontmatter = matter.stringify(rewriteLinks(page.body, aliases), {
      title: page.title,
      ...(page.description ? {description: page.description} : {}),
    });
    await writeFile(destination, frontmatter, 'utf8');
  }
}

/**
 * Viewer固定pageを生成する。
 * @param workspacePath staging workspace。
 * @param pageCount 現在のGenerated Wiki page数。
 * @returns 固定page書込完了時にresolveするPromise。
 * @sideeffect index、graph、空状態pageを作成する。
 */
async function writeViewerPages(workspacePath: string, pageCount: number): Promise<void> {
  const index = `---\ntitle: OpenKB Knowledge\ndescription: OpenKBが生成した社内Knowledge Wiki\n---\n\n# OpenKB Knowledge\n\nOpenKBが生成したKnowledge Wikiを参照します。現在の生成記事数は **${pageCount}** 件です。\n\n- 左側のナビゲーションから記事を選択できます。\n- **Graph View** では記事間のWiki linkを可視化できます。\n`;
  const graph = `---\ntitle: Graph View\ndescription: Generated Wikiの記事とlinkを可視化\nmode: wide\n---\n\n<iframe\n  src="/openkb-graph/index.html"\n  title="OpenKB Knowledge Graph"\n  className="w-full"\n  style={{ height: '72vh', minHeight: '560px', border: 0 }}\n></iframe>\n`;
  const empty = `---\ntitle: 記事はまだありません\ndescription: OpenKB compileの完了待ち\n---\n\nOpenKBによる初回compileが完了すると、生成記事がここへ自動的に追加されます。\n`;
  await writeFile(path.join(workspacePath, 'index.mdx'), index, 'utf8');
  await writeFile(path.join(workspacePath, 'graph.mdx'), graph, 'utf8');
  if (pageCount === 0) {
    await writeFile(path.join(workspacePath, 'generated-empty.mdx'), empty, 'utf8');
  }
}

/**
 * Mintlify docs.json objectを構築する。
 * @param config site名、theme、colorを含むViewer設定。
 * @param pages ナビゲーションへ掲載するSource Page一覧。
 * @returns JSON serialize可能なMintlify設定。
 */
function buildDocsConfig(
  config: ViewerConfig,
  pages: readonly SourcePage[],
): Record<string, unknown> {
  const generatedPages = pages.length > 0 ? buildNavigation(pages) : ['generated-empty'];
  return {
    $schema: 'https://mintlify.com/docs.json',
    theme: config.mintlify.theme,
    name: config.mintlify.name,
    description: 'OpenKBが生成した社内Knowledge Wiki',
    colors: config.mintlify.colors,
    appearance: {default: 'system', strict: false},
    icons: {library: 'lucide'},
    styling: {eyebrows: 'breadcrumbs'},
    navigation: {
      groups: [
        {group: 'Overview', pages: ['index']},
        {group: 'Generated Wiki', pages: generatedPages},
        {group: 'Explore', pages: ['graph']},
      ],
    },
    interaction: {drilldown: false},
    contextual: {options: ['copy', 'view']},
  };
}

/**
 * Source Pageのdirectory構造をMintlify nested groupへ変換する。
 * @param pages ナビゲーション対象page一覧。
 * @returns path階層を保持したnavigation entry一覧。
 */
function buildNavigation(pages: readonly SourcePage[]): Array<string | NavigationGroup> {
  const roots = new Map<string, SourcePage[]>();
  for (const page of pages) {
    const root = page.id.includes('/') ? page.id.split('/')[0] ?? 'Wiki' : 'Wiki';
    const entries = roots.get(root) ?? [];
    entries.push(page);
    roots.set(root, entries);
  }
  return [...roots.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([group, entries]) => ({
      group: humanize(group),
      expanded: false,
      pages: entries.map((page) => page.outputPath.replace(/\.mdx$/, '')),
    }));
}

/**
 * directory名をnavigation表示向けのlabelへ整形する。
 * @param value directory名。
 * @returns 語頭を大文字化した表示label。
 */
function humanize(value: string): string {
  return value
    .replace(/[-_]+/g, ' ')
    .replace(/\b\p{L}/gu, (character) => character.toLocaleUpperCase());
}

/**
 * Source Page本文からCytoscape用graphを構築する。
 * @param pages graph nodeにするSource Page一覧。
 * @param aliases link解決用alias map。
 * @returns node、edge、categoryを持つgraph data。
 */
function buildGraph(
  pages: readonly SourcePage[],
  aliases: ReadonlyMap<string, SourcePage>,
): {nodes: GraphNode[]; edges: GraphEdge[]; categories: string[]} {
  const nodes = pages.map((page) => ({
    data: {
      id: page.id,
      label: page.title,
      category: humanize(page.category),
      description: page.description,
      url: page.url,
    },
  }));
  const edges: GraphEdge[] = [];
  const seen = new Set<string>();
  for (const page of pages) {
    for (const target of extractTargets(page.body)) {
      const resolved = aliases.get(normalizeTarget(target));
      if (!resolved || resolved.id === page.id) continue;
      const edgeId = `${page.id}->${resolved.id}`;
      if (seen.has(edgeId)) continue;
      seen.add(edgeId);
      edges.push({data: {id: edgeId, source: page.id, target: resolved.id}});
    }
  }
  return {
    nodes,
    edges,
    categories: [...new Set(nodes.map((node) => node.data.category))].sort(),
  };
}

/**
 * Wiki linkとMarkdown linkから内部参照候補を抽出する。
 * @param body Markdown本文。
 * @returns link target一覧。
 */
function extractTargets(body: string): string[] {
  const targets: string[] = [];
  for (const match of body.matchAll(WIKILINK_PATTERN)) {
    if (match[1]) targets.push(match[1].trim());
  }
  for (const match of body.matchAll(MARKDOWN_LINK_PATTERN)) {
    const target = match[2]?.split('#', 1)[0];
    if (target && /\.mdx?$/i.test(target)) targets.push(target);
  }
  return targets;
}

/**
 * 例外がfile未作成を表すか判定する。
 * @param error 捕捉した例外。
 * @returns ENOENTの場合true。
 */
function isMissingFileError(error: unknown): boolean {
  return error instanceof Error && 'code' in error && error.code === 'ENOENT';
}
