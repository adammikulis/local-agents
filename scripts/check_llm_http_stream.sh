#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_godot.sh"
. "$ROOT/scripts/lib_capture.sh"
if la_cap_dir >/dev/null; then
    OUT="$(la_headless llm_http_stream)" || exit 2
    printf '%s\n' "$OUT"
    printf '%s\n' "$OUT" | rg -q '^HTTP_STREAM_UNAVAILABLE' && exit 2
    printf '%s\n' "$OUT" | rg -q '^check_llm_http_stream: OK' || exit 1
    exit 0
fi
. "$ROOT/scripts/lib_llm_stream_fixture.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/la_http_stream.XXXXXX")" || exit 2
trap 'la_stream_fixture_stop; rm -rf "$WORK"' EXIT
la_stream_fixture_start "$ROOT" "$WORK" || exit 2
LA_GODOT_TIMEOUT=60 la_godot --headless --no-window --path "$ROOT" -s addons/local_agents/tests/check_llm_http_stream_entry.gd
