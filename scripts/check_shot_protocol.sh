#!/usr/bin/env bash
# ONE RUN, MANY PICTURES. The shot protocol moves the camera through a list of poses in a single launch
# and photographs each. This holds it to that: one PNG per pose, each carrying the pose it was asked for,
# each a lit scene rather than one flat colour, and NO TWO CONSECUTIVE FRAMES THE SAME — a pose that
# never moves the camera photographs the previous one again, and identical bytes are how that shows.
# EXIT 0 every pose is its own picture · 1 one is not · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
require_tool cmp
SCENE="addons/local_agents/examples/SliceRung0Demo.tscn"
# The gate's own protocol: eye level, up and back, and over the top of the box looking down. Spanning
# poses whose pictures cannot coincide, inside the run ceiling docs/RUN_TIMEOUT_CEILING declares.
SHOTS="${LA_SHOT_PROTOCOL:-30:-3:0;2000:-35:0;2000:-35:180;10000:-60:0}"

DIR="$(mktemp -d "${TMPDIR:-/tmp}/la_shot_gate.XXXXXX")"
LOG="$(mktemp "${TMPDIR:-/tmp}/la_shot_gate_log.XXXXXX")"
trap 'rm -rf "$DIR" "$LOG"' EXIT

LA_SHOTS="$SHOTS" "$ROOT/scripts/shoot_demo.sh" "$SCENE" "$DIR" > "$LOG" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
	echo "check_shot_protocol: the protocol run exited $rc, so no pose was photographed." >&2
	tail -25 "$LOG" >&2
	exit 2
fi

WANT=()
while IFS= read -r p; do WANT+=("$p"); done < <(printf '%s' "$SHOTS" | tr ';' '\n' | grep .)
LINES=()
while IFS= read -r l; do LINES+=("$l"); done < <(grep '^SHOT_SAVED=' "$LOG")
require_scanned "${#LINES[@]}" "${#WANT[@]}" "published shots"

fail=0
prev=""
for i in "${!WANT[@]}"; do
	line="${LINES[$i]}"
	path="$(printf '%s' "$line" | cut -d= -f2- | cut -d' ' -f1)"
	# THE PICTURE IS THE POSE IT WAS ASKED FOR, in the order it was asked in.
	pose="$(printf '%s' "$line" | rg -N -o -e 'shot_pose=[-0-9:]+' | cut -d= -f2)"
	idx="$(printf '%s' "$line" | rg -N -o -e 'shot_index=[0-9]+' | cut -d= -f2)"
	want="$(printf '%s' "${WANT[$i]}" | awk -F: '{ printf "%d:%d:%d", $1, $2, $3 }')"
	if [ "$pose" != "$want" ] || [ "$idx" != "$i" ]; then
		echo "FAIL  shot $i was asked for pose $want and published index=${idx:-none} pose=${pose:-none}." >&2
		fail=1
		continue
	fi
	if [ ! -s "$path" ]; then
		echo "FAIL  pose $want published $path and no such picture was written." >&2
		fail=1
		continue
	fi
	# AND THE EYE WENT WHERE IT WAS TOLD: the aim the frame was taken at is the aim that was asked for.
	aimed="$(printf '%s' "$line" | rg -N -o -e 'cam_pitch_deg=-?[0-9.]+' | cut -d= -f2)"
	asked="$(printf '%s' "${WANT[$i]}" | cut -d: -f2)"
	if [ -z "$aimed" ]; then
		echo "FAIL  pose $want did not say where the eye was aimed." >&2
		fail=1
		continue
	fi
	awk -v a="$aimed" -v b="$asked" 'BEGIN { exit (a - b < 1.0 && b - a < 1.0) ? 0 : 1 }' || {
		echo "FAIL  pose $want was photographed with the camera pitched $aimed degrees." >&2
		fail=1
	}
	# AND IT IS A PICTURE OF SOMETHING: read off the frame itself, a scene with no sky/ground step and
	# no relief along its rows is one flat colour, whatever brightness it is flat at.
	mean="$(printf '%s' "$line" | rg -N -o -e 'scene_mean=-?[0-9.]+' | cut -d= -f2)"
	contrast="$(printf '%s' "$line" | rg -N -o -e 'scene_contrast=-?[0-9.]+' | cut -d= -f2)"
	if [ -z "$mean" ] || [ -z "$contrast" ]; then
		echo "FAIL  pose $want said nothing about what its frame held." >&2
		fail=1
		continue
	fi
	awk -v m="$mean" -v c="$contrast" 'BEGIN { exit (m > 0.0 && c > 0.0) ? 0 : 1 }' || {
		echo "FAIL  pose $want photographed one flat colour (mean $mean, contrast $contrast)." >&2
		fail=1
	}
	# AND IT IS A DIFFERENT PICTURE. A pose that never moved the camera re-photographs the last frame.
	if [ -n "$prev" ] && cmp -s "$prev" "$path"; then
		echo "FAIL  pose $want is byte-for-byte the picture before it: the camera never moved." >&2
		fail=1
	fi
	prev="$path"
done

[ "$fail" -eq 0 ] || exit 1
echo "check_shot_protocol: OK (${#WANT[@]} poses, one distinct picture each)"
