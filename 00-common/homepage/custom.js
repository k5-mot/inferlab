/**
 * 構成図の表示領域を作成します。
 *
 * 引数はありません。
 *
 * @returns {HTMLElement} Homepage末尾へ追加する構成図sectionを返します。
 *
 * @sideEffects DOM要素を生成しますが、この関数単体ではdocumentへ追加しません。
 */
function createArchitectureDiagramSection() {
  const section = document.createElement("section");
  section.id = "architecture-diagram";

  const title = document.createElement("h2");
  title.textContent = "Architecture";

  const link = document.createElement("a");
  link.href = "/assets/DIAGRAM.svg";
  link.target = "_blank";
  link.rel = "noopener noreferrer";
  link.ariaLabel = "service architecture diagram";

  const image = document.createElement("img");
  image.src = "/assets/DIAGRAM.svg";
  image.alt = "Service architecture diagram";
  image.loading = "lazy";

  link.appendChild(image);
  section.appendChild(title);
  section.appendChild(link);

  return section;
}

/**
 * Homepageの主表示領域末尾へ構成図を追加します。
 *
 * 引数はありません。
 *
 * @returns {boolean} 追加済みまたは追加成功ならtrue、追加先が未検出ならfalseを返します。
 *
 * @sideEffects document内の末尾へ構成図sectionを追加します。
 */
function appendArchitectureDiagram() {
  if (document.getElementById("architecture-diagram")) {
    return true;
  }

  const target = document.querySelector("main") || document.querySelector("#__next");
  if (!target) {
    return false;
  }

  target.appendChild(createArchitectureDiagramSection());
  return true;
}

/**
 * Homepageの描画完了を待って構成図を差し込みます。
 *
 * 引数はありません。
 *
 * @returns {void}
 *
 * @sideEffects DOMContentLoaded後にMutationObserverを作成し、成功またはtimeoutで停止します。
 */
function initializeArchitectureDiagram() {
  if (appendArchitectureDiagram()) {
    return;
  }

  const observer = new MutationObserver(() => {
    if (appendArchitectureDiagram()) {
      observer.disconnect();
    }
  });

  observer.observe(document.body, { childList: true, subtree: true });
  window.setTimeout(() => observer.disconnect(), 15000);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", initializeArchitectureDiagram);
} else {
  initializeArchitectureDiagram();
}
