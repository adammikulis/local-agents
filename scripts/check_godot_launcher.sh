#!/usr/bin/env bash
# Every godot launch goes through la_godot, so exactly one place decides where the window lands.
# EXIT 0 clean · 1 a direct launch · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
LIB="$ROOT/scripts/lib_godot.sh"
[ -f "$LIB" ] || { echo "check_godot_launcher: MISSING $LIB" >&2; exit 2; }
grep -q '"\$binary"' "$LIB" || { echo "check_godot_launcher: $LIB launches nothing." >&2; exit 2; }

SCAN="${1:-$ROOT/scripts}"
hits="$(rg -n --no-heading -g '*.sh' -g '!lib_godot.sh' -g '!check_godot_launcher.sh' \
	'(^|[^-[:alnum:]_/."])(\$GODOT|"\$GODOT"|godot)[[:space:]]+-' "$SCAN" 2>/dev/null \
	| grep -vE 'command -v|require_tool|which |echo |printf |^[^:]+:[0-9]+:[[:space:]]*#' || true)"

if [ -n "$hits" ]; then
	printf '%s\n' "$hits" >&2
	echo "" >&2
	echo "FAIL  the line(s) above launch godot directly. Source scripts/lib_godot.sh and call la_godot:" >&2
	echo "      a second launch path is a second place to forget --position, and the window lands on the" >&2
	echo "      user's screen. create_local_rendering_device() is null under --headless, so a GPU run" >&2
	echo "      opens a real window and off-view is the only thing keeping it out of the way." >&2
	exit 1
fi
echo "check_godot_launcher: OK (every launch goes through la_godot)"
