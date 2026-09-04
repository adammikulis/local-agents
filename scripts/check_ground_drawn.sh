#!/usr/bin/env bash
# THE DEMO LOOKS AT THE WORLD IT IS STANDING ON. The shot is taken once the ground under the camera is
# drawn, and publishes where the eye stood, what the 3-D half of the frame holds, and — with
# LA_GROUND_SLICE set — whether the eye stood INSIDE the slice box and how many glyphs it drew.
# EXIT 0 the eye stands over built, drawn ground and is aimed at it · 1 it is not · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
PNG="$(mktemp "${TMPDIR:-/tmp}/la_ground.XXXXXX").png"
LOG="$(mktemp "${TMPDIR:-/tmp}/la_ground_log.XXXXXX")"
trap 'rm -f "$PNG" "$LOG"' EXIT

# THE ACCEPTANCE ARM IS THE SLICE: its box is framed and the wind drawn over it. LA_GROUND_BODY=1 frames
# the whole body instead, with no vector source, so the arrow count is not asked for.
EXTRA=()
if [ "${LA_GROUND_BODY:-}" = "" ]; then
	SLICE="${LA_GROUND_SLICE:-$("$ROOT/scripts/sim_run.sh" --print-slice-box)}"
	export LA_SLICE_BOX="$SLICE"
	EXTRA=("--vectors=wind")
else
	SLICE=""
fi

# --shoot-frames is a FLOOR, not the shot: the scene is asked every frame past it whether the ground
# under the eye has arrived, and is photographed when it says yes. Raising it hides a slow mesher.
LA_RUN_TIMEOUT="${LA_GROUND_TIMEOUT:-100}" "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
	addons/local_agents/game/VoxelWorld.tscn \
	-- --sandbox --planet-only --no-fauna --rung=0 --ui "--shoot=$PNG" \
	"--shoot-frames=${LA_GROUND_FRAMES:-60}" ${EXTRA[@]+"${EXTRA[@]}"} > "$LOG" 2>&1

shot="$(grep -m1 '^SHOT_SAVED=' "$LOG")"
if [ -z "$shot" ]; then
	echo "check_ground_drawn: the run published no shot, so nothing was photographed." >&2
	tail -20 "$LOG" >&2
	exit 2
fi
echo "$shot"

read_num() { printf '%s' "$shot" | rg -N -o -e "$1=-?[0-9.]+" | rg -N -o -e '\-?[0-9.]+'; }
read_flag() { printf '%s' "$shot" | rg -N -o -e "$1=(true|false)" | rg -N -o -e '(true|false)'; }

meshed="$(read_flag ground_meshed)"
if [ "$meshed" != "true" ]; then
	echo "check_ground_drawn: the terrain under the camera was never built in this run's frames," >&2
	echo "  so the picture is of a body that had not arrived. Nothing was measured." >&2
	exit 2
fi

alt="$(read_num cam_alt_m)"
pitch="$(read_num cam_pitch_deg)"
ahead="$(read_num ground_ahead_m)"
aim="$(read_num aim_ahead_m)"
mean="$(read_num scene_mean)"
var="$(read_num scene_var)"
if [ -z "$alt" ] || [ -z "$pitch" ] || [ -z "$ahead" ] || [ -z "$aim" ] || [ -z "$mean" ] || [ -z "$var" ]; then
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
# AND THE WORLD IS IN THE PICTURE. Read off the middle of the frame, clear of the HUD bands: an unlit or
# undrawn world is near-black and featureless there, whatever the panels around the edge are doing.
awk -v m="$mean" -v v="$var" 'BEGIN { exit (m > 0.02 && v > 1.0e-4) ? 0 : 1 }' || {
	echo "FAIL  the middle of the frame reads ${mean} mean, ${var} variance: the world is not in the" >&2
	echo "  picture — one flat colour is a frame that drew nothing, black or white." >&2
	fail=1
}

if [ -n "$SLICE" ]; then
	inside="$(read_flag cam_in_slice)"
	arrows="$(read_num field_arrows)"
	[ "$inside" = "true" ] || {
		echo "FAIL  the eye stands OUTSIDE the slice box it was given: it framed some other place." >&2
		fail=1
	}
	awk -v n="${arrows:-0}" 'BEGIN { exit (n > 0) ? 0 : 1 }' || {
		echo "FAIL  the run drew ${arrows:-0} field-vector glyphs, so the field is not in the picture." >&2
		fail=1
	}
fi

[ "$fail" -eq 0 ] || exit 1
echo "check_ground_drawn: OK (the eye is ${alt} m up, pitched ${pitch}, framing ground at ${aim} m and meeting it at ${ahead} m)"
