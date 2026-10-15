#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool "${CXX:-c++}"
require_tool timeout
EXT="$ROOT/addons/local_agents/gdextensions/localagents"
BIN="$(mktemp "${TMPDIR:-/tmp}/la_seed_cancel.XXXXXX")"
trap 'rm -f "$BIN"' EXIT
"${CXX:-c++}" -std=c++17 -pthread -I"$EXT/include" "$EXT/tests/SeedCancellationTest.cpp" -o "$BIN" || exit 2
timeout 5 "$BIN" || exit 1
echo "check_seed_cancellation: OK"
