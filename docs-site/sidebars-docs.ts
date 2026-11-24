import type { SidebarsConfig } from "@docusaurus/plugin-content-docs";

const componentReadmes = [
  "README",
  "keycloak/README",
  "inference/README",
  "rag/README",
  "registry/README",
  "translate/README",
  "owui/README",
  "dify/README",
  "ragflow/README",
  "cloudflareos/README",
  "nextcloud/README",
  "xwiki/README",
  "zulip/README",
  "gitlab/README",
  "o11y/README",
  "langfuse/README",
  "scripts/README",
];

const sidebars: SidebarsConfig = {
  docsSidebar: [
    {
      type: "category",
      label: "運用manual",
      items: [
        "docs/manual/DIFY_AIRGAP",
        "docs/manual/DOWNLOAD",
        "docs/manual/INITIAL_SETUP",
        {
          type: "category",
          label: "Migration",
          items: [
            "docs/manual/migration/README",
            "docs/manual/migration/OPENCLAW",
            "docs/manual/migration/KANEO",
            "docs/manual/migration/ZULIP",
            "docs/manual/migration/DIFY",
            "docs/manual/migration/NEXTCLOUD",
            "docs/manual/migration/VERDACCIO",
            "docs/manual/migration/RAGFLOW",
            "docs/manual/migration/OPENSEARCH",
          ],
        },
        "docs/manual/REGISTRY",
        "docs/manual/TEST",
      ],
    },
    {
      type: "category",
      label: "Troubleshooting",
      items: [
        "docs/troubleshooting/OPENWEBUI_DOCLING_LOAD",
        "docs/troubleshooting/TEI_RESOURCE_EXHAUSTION",
      ],
    },
    {
      type: "category",
      label: "Project rule",
      items: ["docs/rules/CODING_RULES", "docs/rules/CONTRIBUTING"],
    },
    {
      type: "category",
      label: "README",
      items: componentReadmes,
    },
  ],
};

export default sidebars;
