#!/usr/bin/env bash
# ONE RUN, MANY PICTURES: one PNG per pose, each the pose it was asked for, a lit scene, no HUD panel over
# it, and NO TWO CONSECUTIVE FRAMES THE SAME (a pose that never moves the camera repeats the last frame).
# THE GROUND IS A LIT SURFACE AND NOT A PLATE: over the lower half of each of the first two frames the
# median per-row standard deviation of luminance beats one 8-bit step.
# EXIT 0 every pose is its own picture and holds · 1 one does not · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_shot_arm.sh"
require_tool rg
require_tool cmp
require_tool python3
python3 -c "import PIL.Image" 2>/dev/null || {
	echo "check_shot_protocol: python3 cannot open a PNG (no Pillow), so no picture was examined." >&2
	exit 2
}
LOOK_POSES=2

DIR="$(mktemp -d "${TMPDIR:-/tmp}/la_shot_gate.XXXXXX")"
trap 'rm -rf "$DIR"' EXIT

ARM="$(la_shot_arm protocol "$DIR")" || exit 2
rc="$(cat "$ARM/rc")"
if [ "$rc" -ne 0 ]; then
	echo "check_shot_protocol: the protocol run exited $rc, so no pose was photographed." >&2
	tail -25 "$ARM/run.log" >&2
	exit 2
fi

WANT=()
while IFS= read -r p; do WANT+=("$p"); done < <(printf '%s' "$LA_ARM_PROTOCOL_POSES" | tr ';' '\n' | grep .)
LINES=()
while IFS= read -r l; do LINES+=("$l"); done < <(grep '^SHOT_SAVED=' "$ARM/run.log")
require_scanned "${#LINES[@]}" "${#WANT[@]}" "published shots"

fail=0
prev=""
PNGS=()
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
	PNGS+=("$path")
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
	# AND IT IS THE WORLD, NOT THE INTERFACE: the scene's panels were switched off and none stands over it.
	dropped="$(printf '%s' "$line" | rg -N -o -e 'panels_off=[^ ]*' | cut -d= -f2)"
	hud="$(printf '%s' "$line" | rg -N -o -e 'hud_px=[^ ]*' | cut -d= -f2)"
	case "$dropped" in
		'["'*) ;;
		*) echo "check_shot_protocol: pose $want dropped no panel (${dropped:-none}), so a bare frame asks nothing." >&2
			exit 2 ;;
	esac
	if [ "$hud" != "[]" ]; then
		shown="${hud:-none}"
		echo "FAIL  pose $want was photographed under HUD panels (hud_px ${shown:0:60})." >&2
		fail=1
	fi
	# AND IT IS A DIFFERENT PICTURE. A pose that never moved the camera re-photographs the last frame.
	if [ -n "$prev" ] && cmp -s "$prev" "$path"; then
		echo "FAIL  pose $want is byte-for-byte the picture before it: the camera never moved." >&2
		fail=1
	fi
	prev="$path"
done

python3 - "$LOOK_POSES" "${PNGS[@]}" <<'PY' || fail=1
import sys
from PIL import Image

STEP = 1.0 / 255.0                        # one 8-bit step: the picture's own resolution
n = int(sys.argv[1])
paths = sys.argv[2:2 + n]
if len(paths) < n:
    print("FAIL  the protocol photographed %d pictures and the look claim reads %d." % (len(paths), n),
          file=sys.stderr)
    raise SystemExit(1)

fail = 0
for path in paths:
    im = Image.open(path).convert("L")
    w, h = im.size
    px = im.load()
    lum = [[px[x, y] / 255.0 for x in range(w)] for y in range(h // 2, h)]
    name = path.rsplit("/", 1)[-1]

    # A lit surface varies along a row; a plate does not.
    devs = []
    for row in lum:
        m = sum(row) / len(row)
        devs.append((sum((v - m) ** 2 for v in row) / len(row)) ** 0.5)
    devs.sort()
    if not devs[len(devs) // 2] > STEP:
        print("FAIL  %s draws one flat colour under its horizon: half its rows vary less across the"
              % name, file=sys.stderr)
        print("      frame than the picture's own 8-bit step.", file=sys.stderr)
        fail = 1
raise SystemExit(fail)
PY

[ "$fail" -eq 0 ] || exit 1
echo "check_shot_protocol: OK (${#WANT[@]} poses, one distinct picture each, $LOOK_POSES lit under the horizon)"
