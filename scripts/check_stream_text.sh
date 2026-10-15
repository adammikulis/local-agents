#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool c++
EXT="$ROOT/addons/local_agents/gdextensions/localagents"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/la_stream_text.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
c++ -std=c++17 -I"$EXT/include" "$EXT/src/RuntimeStreamText.cpp" "$EXT/tests/StreamTextTest.cpp" -o "$WORK/stream_text" || exit 2
"$WORK/stream_text"
