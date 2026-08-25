import cytoscape, {type Core, type NodeSingular} from 'cytoscape';
import {createIcons, ExternalLink, Maximize2, RotateCcw, Search, X} from 'lucide';

interface GraphData {
  readonly nodes: Array<{
    readonly data: {
      readonly id: string;
      readonly label: string;
      readonly category: string;
      readonly description: string;
      readonly url: string;
    };
  }>;
  readonly edges: Array<{
    readonly data: {
      readonly id: string;
      readonly source: string;
      readonly target: string;
    };
  }>;
  readonly categories: string[];
}

declare global {
  interface Window {
    __OPENKB_GRAPH__?: GraphData;
  }
}

const CATEGORY_COLORS = [
  '#0f766e',
  '#2563eb',
  '#9333ea',
  '#c2410c',
  '#be123c',
  '#4d7c0f',
  '#0369a1',
  '#7c3aed',
];

/**
 * 必須DOM elementを型付きで取得する。
 * @param id element id。
 * @returns 対象DOM element。
 * @throws elementが存在しない場合。
 */
function requireElement<T extends HTMLElement>(id: string): T {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Graph elementが見つかりません: ${id}`);
  return element as T;
}

/**
 * graph dataを取得してinteractive viewを初期化する。
 * @returns 初期化完了時にresolveするPromise。
 * @throws data取得またはCytoscape初期化に失敗した場合。
 * @sideeffect DOMへgraph、filter、event handlerを設定する。
 */
async function initialize(): Promise<void> {
  const graph = window.__OPENKB_GRAPH__;
  if (!graph) throw new Error('Graph dataが読み込まれていません');
  const colors = new Map(
    graph.categories.map((category, index) => [
      category,
      CATEGORY_COLORS[index % CATEGORY_COLORS.length] ?? '#475569',
    ]),
  );
  const cytoscapeView = createGraph(graph, colors);
  renderLegend(cytoscapeView, graph.categories, colors);
  bindToolbar(cytoscapeView);
  bindSelection(cytoscapeView);
  updateCounts(cytoscapeView);
  createIcons({icons: {ExternalLink, Maximize2, RotateCcw, Search, X}});
}

/**
 * Cytoscape instanceを生成する。
 * @param graph 表示するnodeとedge。
 * @param colors category別color map。
 * @returns 初期化済みCytoscape core。
 * @sideeffect graph containerへcanvasを挿入する。
 */
function createGraph(graph: GraphData, colors: ReadonlyMap<string, string>): Core {
  return cytoscape({
    container: requireElement('graph-canvas'),
    elements: [...graph.nodes, ...graph.edges],
    style: [
      {
        selector: 'node',
        style: {
          'background-color': (element) => colors.get(String(element.data('category'))) ?? '#475569',
          label: 'data(label)',
          color: '#172033',
          'font-family': 'Inter, ui-sans-serif, system-ui, sans-serif',
          'font-size': 11,
          'text-wrap': 'ellipsis',
          'text-max-width': '130px',
          'text-valign': 'bottom',
          'text-margin-y': 8,
          width: 24,
          height: 24,
          'border-width': 3,
          'border-color': '#ffffff',
          'overlay-opacity': 0,
        },
      },
      {
        selector: 'node:selected',
        style: {
          width: 34,
          height: 34,
          'border-color': '#111827',
          'border-width': 4,
        },
      },
      {
        selector: 'edge',
        style: {
          width: 1.5,
          'line-color': '#9aa4b2',
          'target-arrow-color': '#9aa4b2',
          'target-arrow-shape': 'triangle',
          'curve-style': 'bezier',
          opacity: 0.62,
          'arrow-scale': 0.7,
        },
      },
      {
        selector: '.dimmed',
        style: {opacity: 0.1},
      },
      {
        selector: '.matched',
        style: {'border-color': '#f59e0b', 'border-width': 5},
      },
    ],
    layout: {
      name: graph.nodes.length > 1 ? 'cose' : 'grid',
      animate: false,
      randomize: true,
      fit: true,
      padding: 48,
      nodeRepulsion: () => 7000,
      idealEdgeLength: () => 120,
    },
    minZoom: 0.25,
    maxZoom: 2.5,
  });
}

/**
 * category filterをlegendへ描画する。
 * @param graph 表示対象Cytoscape core。
 * @param categories category一覧。
 * @param colors category別color map。
 * @returns 戻り値はない。
 * @sideeffect legendへcheckboxを追加する。
 */
function renderLegend(
  graph: Core,
  categories: readonly string[],
  colors: ReadonlyMap<string, string>,
): void {
  const legend = requireElement('legend');
  if (categories.length === 0) {
    legend.textContent = '記事はまだありません';
    return;
  }
  for (const category of categories) {
    const label = document.createElement('label');
    label.className = 'legend-item';
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.checked = true;
    checkbox.addEventListener('change', () => {
      graph
        .nodes()
        .filter((node) => node.data('category') === category)
        .style('display', checkbox.checked ? 'element' : 'none');
      updateCounts(graph);
      graph.fit(graph.elements(':visible'), 40);
    });
    const swatch = document.createElement('span');
    swatch.className = 'legend-swatch';
    swatch.style.backgroundColor = colors.get(category) ?? '#475569';
    const text = document.createElement('span');
    text.textContent = category;
    label.append(checkbox, swatch, text);
    legend.append(label);
  }
}

/**
 * 検索、fit、layout再計算のtoolbar操作を登録する。
 * @param graph 操作対象Cytoscape core。
 * @returns 戻り値はない。
 * @sideeffect toolbarへevent listenerを設定する。
 */
function bindToolbar(graph: Core): void {
  const search = requireElement<HTMLInputElement>('search');
  search.addEventListener('input', () => {
    const query = search.value.trim().toLocaleLowerCase();
    graph.elements().removeClass('dimmed matched');
    if (!query) return;
    const matches = graph.nodes().filter((node) =>
      String(node.data('label')).toLocaleLowerCase().includes(query),
    );
    graph.elements().addClass('dimmed');
    matches.removeClass('dimmed').addClass('matched');
    matches.connectedEdges().removeClass('dimmed');
    if (matches.length > 0) graph.fit(matches, 80);
  });
  requireElement('fit').addEventListener('click', () => graph.fit(graph.elements(':visible'), 48));
  requireElement('relayout').addEventListener('click', () => {
    graph.layout({name: graph.nodes().length > 1 ? 'cose' : 'grid', animate: true}).run();
  });
}

/**
 * node選択時に詳細panelを更新する。
 * @param graph 選択eventを監視するCytoscape core。
 * @returns 戻り値はない。
 * @sideeffect graphとclose buttonへevent listenerを設定する。
 */
function bindSelection(graph: Core): void {
  graph.on('tap', 'node', (event) => showDetails(event.target as NodeSingular));
  graph.on('tap', (event) => {
    if (event.target === graph) hideDetails();
  });
  requireElement('close-details').addEventListener('click', hideDetails);
}

/**
 * 選択nodeのmetadataを詳細panelへ表示する。
 * @param node 選択されたCytoscape node。
 * @returns 戻り値はない。
 * @sideeffect 詳細panelの内容と表示状態を更新する。
 */
function showDetails(node: NodeSingular): void {
  requireElement('detail-category').textContent = String(node.data('category'));
  requireElement('detail-title').textContent = String(node.data('label'));
  requireElement('detail-description').textContent =
    String(node.data('description')) || '説明は設定されていません。';
  const link = requireElement<HTMLAnchorElement>('detail-link');
  link.href = String(node.data('url'));
  requireElement('details').classList.add('is-open');
}

/**
 * node詳細panelを閉じる。
 * @returns 戻り値はない。
 * @sideeffect 詳細panelを非表示にする。
 */
function hideDetails(): void {
  requireElement('details').classList.remove('is-open');
}

/**
 * 現在表示中のnodeとedge件数を更新する。
 * @param graph 集計対象Cytoscape core。
 * @returns 戻り値はない。
 * @sideeffect count表示を書き換える。
 */
function updateCounts(graph: Core): void {
  const nodes = graph.nodes(':visible').length;
  const edges = graph.edges().filter((edge) => edge.source().visible() && edge.target().visible()).length;
  requireElement('counts').textContent = `${nodes} articles / ${edges} links`;
}

void initialize().catch((error: unknown) => {
  requireElement('graph-canvas').textContent =
    error instanceof Error ? error.message : String(error);
});
