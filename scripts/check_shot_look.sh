#!/usr/bin/env bash
# WHAT THE PICTURES LOOK LIKE, off the pixels, over the frame no HUD covers. THE GROUND IS A LIT SURFACE
# AND NOT A PLATE: over the lower half of that window the median per-row standard deviation of luminance
# beats one 8-bit step, which one flat colour reads zero for at any brightness.
# EXIT 0 every picture holds * 1 one does not * 2 the gate could not run.
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

raise SystemExit(1 if fail else 0)
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
echo "check_shot_look: OK (${#PNGS[@]} pictures, lit under the horizon)"
