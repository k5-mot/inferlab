import { cp, copyFile, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const siteDirectory = dirname(dirname(fileURLToPath(import.meta.url)));
const repositoryDirectory = dirname(siteDirectory);
const generatedDirectory = join(siteDirectory, ".generated-content");
const generatedOpenSpecDirectory = join(generatedDirectory, "openspec");
const generatedDocsDirectory = join(generatedDirectory, "general");
const componentDirectories = [
  "01-keycloak",
  "10-inference",
  "11-rag",
  "12-registry",
  "13-translate",
  "20-owui",
  "21-dify",
  "22-ragflow",
  "25-cloudflareos",
  "26-octos",
  "27-aion",
  "28-assistantmd",
  "30-nextcloud",
  "31-xwiki",
  "33-zulip",
  "34-gitlab",
  "41-llmwiki",
  "42-sage-wiki",
  "50-o11y",
  "51-langfuse",
  "scripts",
  "scripts/oikb",
];

if (siteDirectory !== join(repositoryDirectory, "docs-site")) {
  throw new Error("生成先がdocs-site直下ではありません");
}

// 毎回空の生成先から始め、削除済みの正規文書がsiteへ残留することを防ぎます。
await rm(generatedDirectory, { recursive: true, force: true });
await mkdir(generatedOpenSpecDirectory, { recursive: true });
await mkdir(generatedDocsDirectory, { recursive: true });
await cp(
  join(repositoryDirectory, "openspec", "specs"),
  join(generatedOpenSpecDirectory, "specs"),
  { recursive: true },
);
await cp(
  join(repositoryDirectory, "openspec", "changes"),
  join(generatedOpenSpecDirectory, "changes"),
  { recursive: true },
);
const openSpecHome = join(
  generatedOpenSpecDirectory,
  "specs",
  "shared-platform",
  "spec.md",
);
const openSpecHomeContent = await readFile(openSpecHome, "utf8");

// OpenSpecの共有仕様をrootにし、独立したhome pageの二重管理を避けます。
await writeFile(openSpecHome, `---\nslug: /\n---\n${openSpecHomeContent}`);
await cp(
  join(repositoryDirectory, "docs"),
  join(generatedDocsDirectory, "docs"),
  {
    recursive: true,
  },
);
await copyFile(
  join(repositoryDirectory, "README.md"),
  join(generatedDocsDirectory, "README.md"),
);

for (const componentDirectory of componentDirectories) {
  const outputDirectory = join(generatedDocsDirectory, componentDirectory);
  await mkdir(outputDirectory, { recursive: true });
  await copyFile(
    join(repositoryDirectory, componentDirectory, "README.md"),
    join(outputDirectory, "README.md"),
  );
}
