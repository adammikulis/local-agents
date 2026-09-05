#!/usr/bin/env bash
# PHOTOGRAPH A DEMO SCENE FROM EVERY DISTANCE IT IS MEANT TO BE LOOKED AT, in ONE launch, printing the
# PNG paths. A pose is `alt_m:pitch_deg:yaw_deg` at the scene's framed site: metres over the ground,
# degrees from the horizon (negative down), degrees of bearing; `;` separates poses.
#   scripts/shoot_demo.sh <scene.tscn> [outdir] [--hour=H] [--shots=SPEC]   Env: LA_SHOTS,
#   LA_SHOOT_FRAMES, LA_SHOOT_SIZE, LA_SHOOT_TIMEOUT. EXIT 0 all posed · 1 run failed · 2 cannot run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
require_tool awk

SCENE="${1:-}"
[ -n "$SCENE" ] || { sed -n '2,6p' "$0"; exit 2; }
shift
OUT=""
HOUR=12
SHOTS="${LA_SHOTS:-}"
while [ $# -gt 0 ]; do
	case "$1" in
		--hour=*) HOUR="${1#--hour=}" ;;
		--shots=*) SHOTS="${1#--shots=}" ;;
		--*) echo "shoot_demo: unknown argument '$1'" >&2; exit 2 ;;
		*) OUT="$1" ;;
	esac
	shift
done
[ -f "$ROOT/$SCENE" ] || { echo "shoot_demo: no scene at $ROOT/$SCENE" >&2; exit 2; }
OUT="${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/la_shots.XXXXXX")}"
mkdir -p "$OUT" || exit 2

# THE BOX SAYS HOW FAR OUT THE FAR POSES STAND: half its vertical span is its top, and a picture from
# above the box is a picture of the whole world this run contains.
box_spec() {
	local spec
	spec="$(rg -N -o -e 'slice_box\s*=\s*"[^"]+"' "$ROOT/$SCENE" | head -1 | sed 's/.*"\(.*\)"/\1/')"
	[ -n "$spec" ] || spec="$("$ROOT/scripts/sim_run.sh" --print-slice-box 2>/dev/null)"
	printf '%s' "$spec"
}
SPEC="$(box_spec)"
TOP="$(printf '%s' "$SPEC" | awk -F, 'NF >= 7 { printf "%d", $5 * $7 / 2 }')"
[ -n "$TOP" ] || { echo "shoot_demo: $SCENE declares no slice box and sim_run.sh printed none." >&2; exit 2; }

# THE DEFAULT PROTOCOL: eye level both ways along the valley, then up and back until the whole box is in
# the frame, then over the top of it looking down and out at the horizon. Camera framing, not physics.
if [ -z "$SHOTS" ]; then
	SHOTS="30:-3:0;30:-3:180;200:-15:0;2000:-35:0;2000:-35:180;10000:-60:0;$TOP:-89:0;$TOP:0:0"
fi
POSES="$(printf '%s' "$SHOTS" | tr ';' '\n' | grep -c .)"

LOG="$(mktemp "${TMPDIR:-/tmp}/la_shots_log.XXXXXX")"
trap 'rm -f "$LOG"' EXIT
LA_RUN_TIMEOUT="${LA_SHOOT_TIMEOUT:-110}" "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" "$SCENE" \
	-- --sandbox "--shoot=$OUT/shot.png" "--shots=$SHOTS" "--local-hour=$HOUR" \
	"--shoot-frames=${LA_SHOOT_FRAMES:-150}" "--shoot-size=${LA_SHOOT_SIZE:-1280x800}" > "$LOG" 2>&1
rc=$?

if grep -qE '^SHOT_SPEC_INVALID=|^SHOT_POSE_UNSUPPORTED=' "$LOG"; then
	grep -E '^SHOT_SPEC_INVALID=|^SHOT_POSE_UNSUPPORTED=' "$LOG" >&2
	exit 2
fi
# A PICTURE TAKEN THROUGH A RENDERER THAT REFUSED A SHADER IS NOT EVIDENCE.
if grep -qE 'SHADER ERROR|Shader compilation failed' "$LOG"; then
	grep -m4 -E 'SHADER ERROR|Shader compilation failed|\.gdshader' "$LOG" >&2
	echo "shoot_demo: the run failed to compile a shader, so the frames are of a broken renderer." >&2
	exit 1
fi

# What each picture was: the run's own line, carrying the pose it was asked for and where the eye stood.
grep '^SHOT_SAVED=' "$LOG" >&2
saved="$(grep -c '^SHOT_SAVED=' "$LOG")"
if [ "$rc" -ne 0 ] || [ "$saved" -ne "$POSES" ]; then
	echo "shoot_demo: asked for $POSES pose(s), the run published $saved and exited $rc." >&2
	tail -20 "$LOG" >&2
	exit 1
fi
grep -o '^SHOT_SAVED=[^ ]*' "$LOG" | cut -d= -f2-
