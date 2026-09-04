#!/usr/bin/env bash
# THE DEMO LOOKS AT THE WORLD IT IS STANDING ON. The shot is taken once the ground under the camera is
# drawn, and publishes where the eye stood, what the SCENE holds with every HUD panel dropped, whether
# the eye stood INSIDE the slice box, and how many field glyphs the rung's own world gave it to draw.
# EXIT 0 the eye stands over built, drawn ground and is aimed at it · 1 it is not · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
PNG="$(mktemp "${TMPDIR:-/tmp}/la_ground.XXXXXX").png"
LOG="$(mktemp "${TMPDIR:-/tmp}/la_ground_log.XXXXXX")"
trap 'rm -f "$PNG" "$LOG"' EXIT

# THE ACCEPTANCE ARM IS THE SLICE: its box is framed and drawn. LA_GROUND_BODY=1 frames the whole body
# instead. NO --vectors IS ASKED FOR: the world draws the highest vector field its own processes make,
# and this gate then holds it to what that rung contains.
if [ "${LA_GROUND_BODY:-}" = "" ]; then
	SLICE="${LA_GROUND_SLICE:-$("$ROOT/scripts/sim_run.sh" --print-slice-box)}"
	export LA_SLICE_BOX="$SLICE"
else
	SLICE=""
fi
# The rung this run's world is built at. A rung solves gravity from 1 and moves momentum from 3, so a
# rung below those has no vector field to draw and must draw none.
RUNG="${LA_GROUND_RUNG:-0}"

# --shoot-frames is a FLOOR, not the shot: the scene is asked every frame past it whether the ground
# ACROSS THE FRAME has arrived and stopped changing, and is photographed when it says yes. The floor is
# how long the world is given to arrive; this box's streamer does not settle inside a shorter one.
LA_RUN_TIMEOUT="${LA_GROUND_TIMEOUT:-100}" "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
	addons/local_agents/game/VoxelWorld.tscn \
	-- --sandbox --planet-only --no-fauna "--rung=$RUNG" --ui "--shoot=$PNG" \
	"--shoot-frames=${LA_GROUND_FRAMES:-150}" > "$LOG" 2>&1

# A PICTURE TAKEN THROUGH A RENDERER THAT REFUSED A SHADER IS NOT EVIDENCE. A .gdshader that fails to
# compile draws black and the run finishes normally, so the shot looks like a measurement and is not one.
if grep -qE 'SHADER ERROR|Shader compilation failed' "$LOG"; then
	echo "check_ground_drawn: the run failed to compile a shader, so the frame is of a broken renderer." >&2
	grep -m4 -E 'SHADER ERROR|Shader compilation failed|\.gdshader' "$LOG" >&2
	exit 2
fi

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
contrast="$(read_num scene_contrast)"
spread="$(read_num scene_spread)"
var_sky="$(read_num scene_var_sky)"
var_ground="$(read_num scene_var_ground)"
split="$(read_num scene_split)"
if [ -z "$alt" ] || [ -z "$pitch" ] || [ -z "$ahead" ] || [ -z "$aim" ] || [ -z "$mean" ] || [ -z "$var" ] \
	|| [ -z "$contrast" ] || [ -z "$spread" ] || [ -z "$split" ] || [ -z "$var_sky" ] \
	|| [ -z "$var_ground" ]; then
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
# AND THE WORLD IS IN THE PICTURE, read off the scene alone with every HUD panel dropped. A LIT
# LANDSCAPE HAS A HORIZON: the shot finds the row that most separates what is above it from what is
# below, and the step across it beats the row-to-row wobble left over on either side. Both sides of the
# comparison come off this shot, so one flat colour reads zero for both and cannot pass at any brightness.
awk -v c="$contrast" -v s="$spread" 'BEGIN { exit (c > 0.0 && c > s) ? 0 : 1 }' || {
	echo "FAIL  the scene splits at ${split} of its height with a ${contrast} step against ${spread} of" >&2
	echo "  wobble: there is no sky/ground horizon in the frame, only one brightness." >&2
	fail=1
}
# AND NEITHER SIDE OF THAT SPLIT IS A FLAT SHEET. Sky carries its scatter gradient and the sun's glow
# across a row; ground carries relief and shading across one. A frame that drew nothing reads zero on
# whichever side it failed, whatever brightness it failed at.
awk -v a="$var_sky" -v b="$var_ground" 'BEGIN { exit (a > 0.0 && b > 0.0) ? 0 : 1 }' || {
	echo "FAIL  above the split the scene varies ${var_sky} along its rows and below it ${var_ground}:" >&2
	echo "  a side reading zero drew one flat colour, not sky or ground." >&2
	fail=1
}

if [ -n "$SLICE" ]; then
	inside="$(read_flag cam_in_slice)"
	[ "$inside" = "true" ] || {
		echo "FAIL  the eye stands OUTSIDE the slice box it was given: it framed some other place." >&2
		fail=1
	}
fi

# A RUNG DRAWS ONLY THE FIELDS ITS OWN WORLD MAKES. Gravity is solved from rung 1 and momentum moves from
# rung 3, so a world below both has no vector field: it must draw NOTHING and say so, and a placeholder
# arrow over a world with no velocity is the picture claiming a measurement nobody took.
arrows="$(read_num field_arrows)"
absent="$(grep -c '^FIELD_VECTORS_ABSENT=' "$LOG")"
if [ "$RUNG" -ge 1 ]; then
	awk -v n="${arrows:-0}" 'BEGIN { exit (n > 0) ? 0 : 1 }' || {
		echo "FAIL  rung ${RUNG} holds a vector field and the run drew ${arrows:-0} glyphs of it." >&2
		fail=1
	}
	[ "$absent" -eq 0 ] || {
		echo "FAIL  rung ${RUNG} holds a vector field, but the run reported it absent:" >&2
		grep -m2 '^FIELD_VECTORS_ABSENT=' "$LOG" >&2
		fail=1
	}
else
	awk -v n="${arrows:-0}" 'BEGIN { exit (n == 0) ? 0 : 1 }' || {
		echo "FAIL  rung ${RUNG} has no gravity and no momentum, so it has no vector field — and the run" >&2
		echo "  drew ${arrows} glyphs of one. An arrow there is a measurement nobody took." >&2
		fail=1
	}
	[ "$absent" -gt 0 ] || {
		echo "FAIL  rung ${RUNG} holds no vector field and the run never said so: no FIELD_VECTORS_ABSENT." >&2
		fail=1
	}
fi

[ "$fail" -eq 0 ] || exit 1
echo "check_ground_drawn: OK (the eye is ${alt} m up, pitched ${pitch}, framing ground at ${aim} m and meeting it at ${ahead} m)"
