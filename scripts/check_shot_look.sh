#!/usr/bin/env bash
# WHAT THE PICTURES LOOK LIKE, off the pixels, over the frame no HUD covers. GROUND AND WATER ARE LIT
# SURFACES: the median per-row standard deviation of luminance beats one 8-bit step, over the lower half
# of the window and over the water half alone. NO BLOCK SEAM CROSSES EITHER: a pixel standing 0.06 of
# full luminance over both shoulders three columns out, chained across rows within one column, may not
# run 40 rows. EXIT 0 both pictures hold * 1 one does not * 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3
python3 -c "import PIL.Image" 2>/dev/null || {
	echo "check_shot_look: python3 cannot open a PNG (no Pillow), so no picture was examined." >&2
	exit 2
}
SCENE="addons/local_agents/examples/SliceRung0Demo.tscn"
SHOTS="${LA_LOOK_SHOTS:-30:-3:0;200:-15:0}"
DIR="$(mktemp -d "${TMPDIR:-/tmp}/la_look.XXXXXX")"
LOG="$(mktemp "${TMPDIR:-/tmp}/la_look_log.XXXXXX")"
trap 'rm -rf "$DIR" "$LOG"' EXIT

LA_SHOTS="$SHOTS" "$ROOT/scripts/shoot_demo.sh" "$SCENE" "$DIR" > "$LOG" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
	echo "check_shot_look: the run exited $rc, so no picture was taken." >&2
	tail -25 "$LOG" >&2
	exit 2
fi
PNGS=()
while IFS= read -r p; do PNGS+=("$p"); done < <(grep -v '^SHOT_SAVED=' "$LOG" | grep '\.png$')
require_scanned "${#PNGS[@]}" "$(printf '%s' "$SHOTS" | tr ';' '\n' | grep -c .)" "pictures to read"

python3 - "${PNGS[@]}" <<'PY'
import sys
from PIL import Image

X0, X1, Y0, Y1 = 0.17, 0.76, 0.19, 0.86   # the frame no HUD panel covers
STEP = 1.0 / 255.0                        # one 8-bit step: the picture's own resolution
RIDGE = 0.06                              # how far over its shoulders a bright thread stands
RIDGE_SPAN = 3                            # columns either side the shoulders are read at
SEAM_ROWS = 40                            # rows a thread may run before it is a seam

fail = 0
for path in sys.argv[1:]:
    im = Image.open(path).convert("L")
    w, h = im.size
    px = im.load()
    x0, x1 = int(X0 * w), int(X1 * w)
    y0, y1 = int(Y0 * h), int(Y1 * h)
    lum = [[px[x, y] / 255.0 for x in range(x0, x1)] for y in range(y0, y1)]
    name = path.rsplit("/", 1)[-1]

    # A lit surface varies along a row; a plate does not.
    devs = []
    for row in lum[len(lum) // 2:]:
        m = sum(row) / len(row)
        devs.append((sum((v - m) ** 2 for v in row) / len(row)) ** 0.5)
    devs.sort()
    med = devs[len(devs) // 2]
    if not med > STEP:
        print("FAIL  %s draws one flat colour under its horizon: half its rows vary less across the"
              % name, file=sys.stderr)
        print("      frame than the picture's own 8-bit step.", file=sys.stderr)
        fail = 1

    # A one-pixel bright thread, chained down the rows.
    prev = {}
    longest = 0
    for row in lum:
        cur = {}
        for i in range(RIDGE_SPAN, len(row) - RIDGE_SPAN):
            if row[i] - max(row[i - RIDGE_SPAN], row[i + RIDGE_SPAN]) > RIDGE:
                run = 1
                for d in (-1, 0, 1):
                    run = max(run, prev.get(i + d, 0) + 1)
                cur[i] = run
                longest = max(longest, run)
        prev = cur
    if longest >= SEAM_ROWS:
        print("FAIL  %s carries a bright thread %d rows long: a seam between mesh blocks, not ground."
              % (name, longest), file=sys.stderr)
        fail = 1

raise SystemExit(1 if fail else 0)
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
echo "check_shot_look: OK (${#PNGS[@]} pictures, lit under the horizon and no seam across them)"
