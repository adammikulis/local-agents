#!/usr/bin/env bash
# An automated run's window is minimized and unfocusable, measured off a real run.
# EXIT 0 clean · 1 a violation · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
HELPER="$ROOT/addons/local_agents/runtime/QuietWindow.gd"
[ -f "$HELPER" ] || { echo "check_quiet_window: MISSING $HELPER" >&2; exit 2; }

fail=0
for want in WINDOW_FLAG_NO_FOCUS window_set_size; do
	rg -q "$want" "$HELPER" || {
		echo "FAIL  $HELPER no longer uses $want, so an automated run can cover or steal focus." >&2
		fail=1
	}
done

if rg -q 'WINDOW_MODE_MINIMIZED' "$ROOT/addons" 2>/dev/null; then
	echo "FAIL  something minimizes the window. A minimized Metal window SIGBUSes in memmove partway" >&2
	echo "      through a run; shrink it with window_set_size instead." >&2
	fail=1
fi

off="$(rg -n --no-heading -g '*.gd' -e 'window_set_position' "$ROOT/addons" \
	-g '!QuietWindow.gd' 2>/dev/null || true)"
if [ -n "$off" ]; then
	printf '%s\n' "$off" >&2
	echo "FAIL  the line(s) above move a window by coordinate. macOS clamps that back onto the screen;" >&2
	echo "      call LAQuietWindow.apply() instead." >&2
	fail=1
fi

[ "$fail" -eq 0 ] || exit 1

out="$(LA_RUN_TIMEOUT="${LA_QW_TIMEOUT:-180}" "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
	addons/local_agents/game/VoxelWorld.tscn --fixed-fps 60 \
	-- --sandbox --planet-only --no-fauna --bare --run-frames=6 2>&1)"
line="$(printf '%s\n' "$out" | grep -m1 '^LA_WINDOW_STATE=')"
if [ -z "$line" ]; then
	echo "check_quiet_window: the run published no LA_WINDOW_STATE, so nothing was measured." >&2
	printf '%s\n' "$out" | tail -20 >&2
	exit 2
fi
echo "$line"
w="$(printf '%s' "$line" | rg -N -o -e '"w":[0-9]+' | rg -N -o -e '[0-9]+')"
h="$(printf '%s' "$line" | rg -N -o -e '"h":[0-9]+' | rg -N -o -e '[0-9]+')"
nofocus="$(printf '%s' "$line" | rg -N -o -e '"no_focus":(true|false)' | rg -N -o -e '(true|false)')"
if [ "$w" -gt 4 ] || [ "$h" -gt 4 ] || [ "$nofocus" != "true" ]; then
	echo "FAIL  a run's window came up ${w}x${h} no_focus=$nofocus. It must be a few pixels and" >&2
	echo "      unfocusable, or it covers the user's work and takes the keyboard." >&2
	exit 1
fi
echo "check_quiet_window: OK (a real run's window is ${w}x${h} and cannot take focus)"
