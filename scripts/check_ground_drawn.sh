#!/usr/bin/env bash
# THE DEMO LOOKS AT THE WORLD IT IS STANDING ON. The shot is taken once the ground under the camera is
# drawn, and publishes where the eye stood, what it was aimed at, and what each half of the frame holds.
# EXIT 0 the eye stands over built ground and is aimed at it · 1 it is not · 2 could not run, a run whose
# terrain never arrived included.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
PNG="$(mktemp "${TMPDIR:-/tmp}/la_ground.XXXXXX").png"
LOG="$(mktemp "${TMPDIR:-/tmp}/la_ground_log.XXXXXX")"
trap 'rm -f "$PNG" "$LOG"' EXIT

LA_RUN_TIMEOUT="${LA_GROUND_TIMEOUT:-100}" "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
	addons/local_agents/game/VoxelWorld.tscn \
	-- --sandbox --planet-only --no-fauna --rung=0 --ui "--shoot=$PNG" \
	"--shoot-frames=${LA_GROUND_FRAMES:-600}" > "$LOG" 2>&1

shot="$(grep -m1 '^SHOT_SAVED=' "$LOG")"
halves="$(grep -m1 '^SHOT_STRUCTURE=' "$LOG")"
if [ -z "$shot" ] || [ -z "$halves" ]; then
	echo "check_ground_drawn: the run published no shot, so nothing was photographed." >&2
	tail -20 "$LOG" >&2
	exit 2
fi
echo "$shot"
echo "$halves"

meshed="$(printf '%s' "$shot" | rg -N -o -e 'ground_meshed=(true|false)' | rg -N -o -e '(true|false)')"
if [ "$meshed" != "true" ]; then
	echo "check_ground_drawn: the terrain under the camera was never built in this run's frames," >&2
	echo "  so the picture is of a body that had not arrived. Nothing was measured." >&2
	exit 2
fi

alt="$(printf '%s' "$shot" | rg -N -o -e 'cam_alt_m=-?[0-9.]+' | rg -N -o -e '\-?[0-9.]+')"
pitch="$(printf '%s' "$shot" | rg -N -o -e 'cam_pitch_deg=-?[0-9.]+' | rg -N -o -e '\-?[0-9.]+')"
ahead="$(printf '%s' "$shot" | rg -N -o -e 'ground_ahead_m=-?[0-9.]+' | rg -N -o -e '\-?[0-9.]+')"
aim="$(printf '%s' "$shot" | rg -N -o -e 'aim_ahead_m=-?[0-9.]+' | rg -N -o -e '\-?[0-9.]+')"
up="$(printf '%s' "$halves" | rg -N -o -e '"upper_mean":[0-9.]+' | rg -N -o -e '[0-9.]+')"
low="$(printf '%s' "$halves" | rg -N -o -e '"lower_mean":[0-9.]+' | rg -N -o -e '[0-9.]+')"
upv="$(printf '%s' "$halves" | rg -N -o -e '"upper":[0-9.]+' | rg -N -o -e '[0-9.]+')"
lowv="$(printf '%s' "$halves" | rg -N -o -e '"lower":[0-9.]+' | rg -N -o -e '[0-9.]+')"
if [ -z "$alt" ] || [ -z "$pitch" ] || [ -z "$ahead" ] || [ -z "$aim" ] || [ -z "$up" ] || [ -z "$low" ]; then
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
# And the ground it framed is BUILT WHERE IT FRAMED IT: the body's own collider stands down the view axis
# at the distance the pose solved for. Kilometres further out is a coarse stand-in, not that ground.
awk -v g="$ahead" -v a="$aim" 'BEGIN { exit (g > 0.0 && a > 0.0 && g < 2.0 * a) ? 0 : 1 }' || {
	echo "FAIL  the view axis meets built ground at ${ahead} m, but the pose framed ground at ${aim} m:" >&2
	echo "  the camera is aimed at a body that has not arrived where it is looking." >&2
	fail=1
}
# A rendered world is not one flat colour: a dead renderer draws two identical, featureless halves.
awk -v u="$up" -v l="$low" -v uv="$upv" -v lv="$lowv" \
	'BEGIN { d = u - l; if (d < 0) d = -d; exit (d > 0.01 || uv > 1.0e-4 || lv > 1.0e-4) ? 0 : 1 }' || {
	echo "FAIL  the frame has no structure at all ($up vs $low): the renderer drew nothing." >&2
	fail=1
}
[ "$fail" -eq 0 ] || exit 1
echo "check_ground_drawn: OK (the eye is ${alt} m up, pitched ${pitch}, framing ground at ${aim} m and meeting it at ${ahead} m)"
