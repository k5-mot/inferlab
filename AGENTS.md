# AGENTS.md

## Scope

- AI agents MUST respond to users in Japanese.
- Contributors and AI agents MUST follow the [coding rules](docs/rules/CODING_RULES.md) when changing code.
- Contributors and AI agents MUST follow the [contribution rules](docs/rules/CONTRIBUTING.md) when working with branches, commits, or tags.
- If a directory contains another `AGENTS.md`, its more specific rules MUST take precedence within that directory.

## Documentation Rules

### Format and Language

- All project documentation MUST use Markdown and MUST have the `.md` extension.
- Documents under `docs/` MUST be written in Japanese.
- Project-governance `AGENTS.md` files MUST be written in English. Runtime persona or workspace `AGENTS.md` files for Hermes, OpenClaw, and QwenPaw MAY use the agent's configured language.
- Language required by an external file format, source code, command, identifier, product name, or quoted specification MAY remain unchanged.

### Normative Language

- The terms `MUST`, `MUST NOT`, `REQUIRED`, `SHALL`, `SHALL NOT`, `SHOULD`, `SHOULD NOT`, `RECOMMENDED`, `NOT RECOMMENDED`, `MAY`, and `OPTIONAL` have the normative meanings defined by RFC 8174 only when written in uppercase.
- Requirements MUST use the normative terms above to make their strength explicit.
- The uppercase terms above MUST NOT be used when their normative meanings are not intended.

### Structure and Content

- Each rule MUST have one authoritative location. The same rule MUST NOT be duplicated across documents.
- References to rules in another document MUST use relative links.
- Headings MUST identify their contents clearly and MUST distinguish procedures, expected results, exceptions, and rollback steps.
- Every executable command in documentation MUST have a comment that explains its purpose.
- Commands requiring elevated privileges MUST show `sudo` explicitly.
- Procedures that change state MUST document their expected results and failure criteria.
- Acronyms, standards, and project-specific terms SHOULD be explained or linked when first introduced.
- Moving or renaming a document MUST update all project-local links in the same change.

### References

- A document that relies on an external specification, official documentation, issue, or article MUST include a final `## References` section.
- A `References` section MUST list only sources actually used by that document.
- Primary sources and official documentation SHOULD be preferred when available.
- A document without external references MAY omit the `References` section.
- No content section MAY appear after `References`.

## References

- [RFC 8174: Ambiguity of Uppercase vs Lowercase in RFC 2119 Key Words](https://www.rfc-editor.org/info/rfc8174/)
