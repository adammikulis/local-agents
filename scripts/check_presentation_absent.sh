#!/usr/bin/env bash
# PRESENTATION IS ABSENT WITHOUT --ui, NOT HIDDEN. An invisible CanvasLayer still runs its scripts.
# The run publishes TREE_PRESENTATION={"scanned":N,"nodes":[...]}: every Control, CanvasLayer and
# node scripted out of game/ui or game/menu in the tree. `scanned` is the positive control.
# EXIT 0 no presentation node · 1 one stood in the tree · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?

if la_cap_dir >/dev/null; then
	line="$(la_marker '^TREE_PRESENTATION=')" || exit 2
else
	out="$(LA_RUN_TIMEOUT="${LA_PRES_TIMEOUT:-120}" "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
		addons/local_agents/game/VoxelWorld.tscn --fixed-fps 60 \
		-- --sandbox --planet-only --no-fauna --run-frames=6 2>&1)"
	line="$(printf '%s\n' "$out" | grep -m1 '^TREE_PRESENTATION=')"
	if [ -z "$line" ]; then
		echo "check_presentation_absent: the run published no TREE_PRESENTATION, so nothing was counted." >&2
		printf '%s\n' "$out" | tail -20 >&2
		exit 2
	fi
fi
echo "$line"

scanned="$(printf '%s' "$line" | rg -N -o -e '"scanned":[0-9]+' | rg -N -o -e '[0-9]+')"
case "${scanned:-0}" in "" | 0) 
	echo "check_presentation_absent: the census walked no node, so its silence proves nothing." >&2
	exit 2 ;;
esac

nodes="$(printf '%s' "$line" | rg -N -o -e '"nodes":\[.*\]')"
if [ -z "$nodes" ]; then
	echo "check_presentation_absent: the census published no node list." >&2
	exit 2
fi
if [ "$nodes" != '"nodes":[]' ]; then
	echo "FAIL  a run with no --ui built the presentation node(s) below. Presentation is ABSENT there:" >&2
	printf '%s\n' "$nodes" | tr ',' '\n' >&2
	echo "      move it under the UiLayer scene, which only a --ui run instantiates." >&2
	exit 1
fi
echo "check_presentation_absent: OK (no presentation node among $scanned, with no --ui)"
