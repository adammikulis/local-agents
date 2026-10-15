#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_capture.sh"
if la_cap_dir >/dev/null; then
    OUT="$(la_headless llm_request_ownership)" || exit 2
    printf '%s\n' "$OUT"
    printf '%s\n' "$OUT" | rg -q 'LLM request ownership tests passed' || exit 1
    exit 0
fi
"$ROOT/scripts/run_single_test.sh" test_llm_request_ownership.gd
