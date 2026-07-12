# Rules

## Comments

- MUST write comments in Japanese.
- MUST write a documentation comment for every function, using the standard format of the language (e.g. JSDoc for TypeScript/JavaScript, docstring for Python).
- Function comments MUST describe: the purpose of the function, its parameters, and its return value.
- SHOULD also describe thrown exceptions and side effects when they exist.
- MUST NOT write comments that merely restate the code. Comments SHOULD explain why, not what.

## Git

### Commit Messages

- MUST write commit messages in Japanese.
- MUST follow the Conventional Commits format, prefixed with a gitmoji:
    ```plaintext
    <gitmoji> <type>(<scope>): <subject>
    ```
- `<scope>` is optional.
- `<subject>` MUST be written in Japanese, within 50 characters, and MUST NOT end with a period (「。」).
- MUST choose the gitmoji that matches the type (e.g. feat → ✨, fix → 🐛, docs → 📝, refactor → ♻️, test → ✅).
- SHOULD add a body (separated by a blank line) explaining the reason for the change when the subject alone is not sufficient.
- MUST NOT mix unrelated changes in one commit.

### Commit Granularity

- MUST commit one logical change per commit. A commit SHOULD be
  revertable on its own without breaking the build.
- MUST separate refactoring from behavior changes
  (e.g. commit `♻️ refactor` first, then `✨ feat`).
- MUST NOT create commits smaller than a meaningful unit
  (e.g. fixing a typo introduced in the same session SHOULD be
  amended, not committed separately).
- MUST ensure the code builds and tests pass at every commit.
- (For AI agents) MUST commit after completing each task or subtask,
  and MUST NOT commit work-in-progress code without being asked.
