#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly RUNNER="${REPO_ROOT}/tests/e2e/run-playwright-smoke.sh"
readonly EXPECTED_CASES=$'nextcloud\nbookstack\nkaneo\nzulip\nopen-webui\ngrafana\nlangfuse'

actual_cases="$(${RUNNER} --list)"

if [[ "${actual_cases}" != "${EXPECTED_CASES}" ]]; then
  echo "Playwright smoke case一覧が期待値と一致しません。" >&2
  printf 'expected:\n%s\nactual:\n%s\n' "${EXPECTED_CASES}" "${actual_cases}" >&2
  exit 1
fi
