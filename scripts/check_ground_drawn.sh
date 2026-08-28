#!/usr/bin/env bash
# THE DEMO LOOKS AT THE WORLD IT IS STANDING ON. The camera's altitude band and its far plane were
# written for a body a few hundred units across; on one of real size the eye sat inside a continent
# and aimed at the sky, and every screenshot was empty.
# The shot publishes where it stood and what each half of the frame looks like.
# EXIT 0 the ground is under the eye and in the frame · 1 it is not · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
PNG="$(mktemp "${TMPDIR:-/tmp}/la_ground.XXXXXX").png"
LOG="$(mktemp "${TMPDIR:-/tmp}/la_ground_log.XXXXXX")"
trap 'rm -f "$PNG" "$LOG"' EXIT

LA_RUN_TIMEOUT="${LA_GROUND_TIMEOUT:-100}" "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
	addons/local_agents/game/VoxelWorld.tscn \
	-- --sandbox --planet-only --no-fauna --ui "--shoot=$PNG" \
	"--shoot-frames=${LA_GROUND_FRAMES:-120}" > "$LOG" 2>&1

shot="$(grep -m1 '^SHOT_SAVED=' "$LOG")"
halves="$(grep -m1 '^SHOT_STRUCTURE=' "$LOG")"
if [ -z "$shot" ] || [ -z "$halves" ]; then
	echo "check_ground_drawn: the run published no shot, so nothing was photographed." >&2
	tail -20 "$LOG" >&2
	exit 2
fi
echo "$shot"
echo "$halves"

alt="$(printf '%s' "$shot" | rg -N -o -e 'cam_alt_m=-?[0-9.]+' | rg -N -o -e '\-?[0-9.]+')"
pitch="$(printf '%s' "$shot" | rg -N -o -e 'cam_pitch_deg=-?[0-9.]+' | rg -N -o -e '\-?[0-9.]+')"
up="$(printf '%s' "$halves" | rg -N -o -e '"upper_mean":[0-9.]+' | rg -N -o -e '[0-9.]+')"
low="$(printf '%s' "$halves" | rg -N -o -e '"lower_mean":[0-9.]+' | rg -N -o -e '[0-9.]+')"
if [ -z "$alt" ] || [ -z "$pitch" ] || [ -z "$up" ] || [ -z "$low" ]; then
	echo "check_ground_drawn: the shot did not say where it stood, so nothing was measured." >&2
	exit 2
fi

fail=0
# The eye is ABOVE the ground it is looking at. Negative means it is inside the rock.
awk -v a="$alt" 'BEGIN { exit (a > 0.0) ? 0 : 1 }' || {
	echo "FAIL  the camera stands ${alt} m above the ground: the eye is inside the body." >&2
	fail=1
}
# And it is aimed DOWN at that ground, not up past the horizon.
awk -v p="$pitch" 'BEGIN { exit (p < 0.0) ? 0 : 1 }' || {
	echo "FAIL  the camera is pitched ${pitch} degrees, so it is aimed above the horizon." >&2
	fail=1
}
# A frame with a horizon in it has two halves that do not match.
awk -v u="$up" -v l="$low" 'BEGIN { d = u - l; if (d < 0) d = -d; exit (d > 0.02) ? 0 : 1 }' || {
	echo "FAIL  the two halves of the frame read the same ($up vs $low): there is no horizon in it." >&2
	fail=1
}
[ "$fail" -eq 0 ] || exit 1
echo "check_ground_drawn: OK (the eye is ${alt} m up, pitched ${pitch}, and the frame has a horizon)"
