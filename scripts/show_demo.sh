#!/usr/bin/env bash
# THE MAINTAINER'S LAUNCH: a demo scene in a real window on the monitor, with focus and sound.
#   scripts/show_demo.sh SliceRung1Demo            # by name under addons/local_agents/examples
#   scripts/show_demo.sh path/to/Scene.tscn -- --seed=3
# Env: LA_WIN_POS (default 120,80), LA_WINDOW_RES (default 1600x1000).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_godot.sh"
[ $# -ge 1 ] || { echo "usage: scripts/show_demo.sh <Scene|scene.tscn> [-- args]" >&2; exit 2; }
SCENE="$1"; shift
case "$SCENE" in
	*.tscn) ;;
	*) SCENE="addons/local_agents/examples/$SCENE.tscn" ;;
esac
[ -f "$ROOT/$SCENE" ] || { echo "show_demo: no scene at $SCENE" >&2; exit 2; }
[ "${1:-}" = "--" ] && shift
cd "$ROOT" || exit 2
LA_SHOW_WINDOW=1 la_godot --path "$ROOT" "$SCENE" -- --sandbox "$@"
