#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_godot.sh"
out="$(LA_CPU_VALIDATION=1 la_godot --headless --path "$ROOT" -s res://addons/local_agents/tests/gate_probe_history.gd 2>&1)"
rc=$?
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || exit "$rc"
printf '%s\n' "$out" | grep -q '^PROBE_HISTORY: OK$' || exit 2
if printf '%s\n' "$out" | grep -qE 'SCRIPT ERROR|Parse Error|^ERROR:'; then exit 2; fi
echo 'check_probe_history: OK'
