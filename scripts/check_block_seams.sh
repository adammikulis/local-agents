#!/usr/bin/env bash
# NO SKY THROUGH THE GROUND WHERE TWO VOXEL BLOCKS MEET. The rung-1 slice is photographed from each protocol
# pose under a kilometre with every block its own flat colour, then with the terrain off. Below the horizon
# every ray ends on the ground, so a pixel there between two blocks that holds the second frame's backdrop
# is a seam. What draws over the ground is switched off; the protocol drops the HUD.
# EXIT 0 no seam · 1 a seam, or no ground below the horizon · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3
python3 -c "import PIL.Image" 2>/dev/null || {
	echo "check_block_seams: python3 cannot open a PNG (no Pillow), so no picture was examined." >&2
	exit 2
}
. "$ROOT/scripts/lib_shot_arm.sh"
DIR="$(mktemp -d "${TMPDIR:-/tmp}/la_seams.XXXXXX")"
trap 'rm -rf "$DIR"' EXIT

ARM="$(la_shot_arm blocks "$DIR")" || exit 2
rc="$(cat "$ARM/rc")"
if [ "$rc" -ne 0 ]; then
	echo "check_block_seams: the run exited $rc, so no picture was taken." >&2
	tail -25 "$ARM/run.log" >&2
	exit 2
fi
require_scanned "$(grep -c '^SHOT_SAVED=' "$ARM/run.log")" 2 "frames of the protocol poses under ${LA_ARM_BLOCKS_UNDER_M} m"

python3 - "$ARM/run.log" <<'PY'
import json, math, sys
from PIL import Image

REACH = 3        # px either side of a seam in which the two blocks must stand
GROUND = 48      # 8-bit steps between the two frames that make a pixel ground
APART = 30       # 8-bit steps between two blocks' colours
SKY_SHARE = 0.5  # the seam pixel is nearer the backdrop than half the way to the blocks either side
BELOW_DEG = 1.0  # degrees under the horizon's dip past which no relief leaves a ray open to the sky
MIN_BORDER = 200 # border pixels a pose must hold for the question to have been asked
MIN_GROUND = 0.9 # share of the uncovered view below the horizon that is ground

shots = {}
for line in open(sys.argv[1], errors="replace"):
    if not line.startswith("SHOT_SAVED="):
        continue
    f = dict(kv.split("=", 1) for kv in line.split()[1:] if "=" in kv)
    path = line.split()[0][len("SHOT_SAVED="):]
    eye = [f.get(k, "") for k in ("cam_pitch_deg", "cam_fov_deg", "horizon_dip_deg")]
    rec = shots.setdefault(f["shot_index"], {"pose": f["shot_pose"], "eye": eye})
    rec["S" if f.get("shot_without") == "terrain" else "B"] = path


def under_horizon(w, h, eye):
    """Per row and column: whether the ray stands BELOW_DEG under the dip of the horizon, no roll."""
    try:
        pitch, fov, dip = (math.radians(float(v)) for v in eye)
    except ValueError:
        return None
    if not all(math.isfinite(v) for v in (pitch, fov, dip)):
        return None
    t, aspect = math.tan(0.5 * fov), w / float(h)
    limit = -math.sin(dip + math.radians(BELOW_DEG))
    rows = []
    for y in range(h):
        dy = (1.0 - 2.0 * (y + 0.5) / h) * t
        rows.append([(dy * math.cos(pitch) + math.sin(pitch))
                     / math.sqrt(((2.0 * (x + 0.5) / w - 1.0) * t * aspect) ** 2 + dy * dy + 1.0) < limit
                     for x in range(w)])
    return rows

def far(a, b):
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2]))

def dist(a, b):
    return ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2) ** 0.5

fail, report = 0, []
steps = range(1, REACH + 1)
for key in sorted(shots, key=int):
    rec = shots[key]
    if "B" not in rec or "S" not in rec:
        print("check_block_seams: pose %s published no pair of frames." % rec["pose"], file=sys.stderr)
        sys.exit(2)
    bi, si = Image.open(rec["B"]).convert("RGB"), Image.open(rec["S"]).convert("RGB")
    w, h = bi.size
    B, S = bi.load(), si.load()
    below = under_horizon(w, h, rec["eye"])
    if below is None:
        print("check_block_seams: pose %s did not say where its eye looked (%s)." % (rec["pose"], rec["eye"]),
              file=sys.stderr)
        sys.exit(2)
    off = [[not v for v in row] for row in below]
    ground = [[not off[y][x] and far(B[x, y], S[x, y]) > GROUND for x in range(w)] for y in range(h)]
    seams, border = [], 0
    for y in range(REACH, h - REACH):
        for x in range(REACH, w - REACH):
            if off[y][x]:
                continue
            between, seam = False, False
            for dx, dy in ((1, 0), (0, 1)):
                q1 = next(((x - dx * k, y - dy * k) for k in steps if ground[y - dy * k][x - dx * k]), None)
                q2 = next(((x + dx * k, y + dy * k) for k in steps if ground[y + dy * k][x + dx * k]), None)
                if q1 is None or q2 is None or far(B[q1], B[q2]) <= APART:
                    continue
                between = True
                s = S[x, y]
                seam = seam or dist(B[x, y], s) <= SKY_SHARE * min(dist(B[q1], s), dist(B[q2], s))
            border += between
            if seam:
                seams.append((x, y))
    seen = [(x, y) for y in range(h) for x in range(w) if not off[y][x]]
    share = sum(1 for x, y in seen if ground[y][x]) / float(max(len(seen), 1))
    report.append({"pose": rec["pose"], "seams": len(seams), "border_px": border, "ground": round(share, 3)})
    if border < MIN_BORDER:
        print("check_block_seams: pose %s shows %d px between two painted blocks, so the blocks were not "
              "painted apart and no border was examined." % (rec["pose"], border), file=sys.stderr)
        sys.exit(2)
    if share < MIN_GROUND:
        print("FAIL  pose %s: %.0f%% of the uncovered view below the horizon is ground: the blocks are not "
              "drawn where the body is." % (rec["pose"], 100.0 * share), file=sys.stderr)
        fail = 1
    if seams:
        print("FAIL  pose %s: %d px between two blocks show the backdrop, first at %s." % (rec["pose"],
              len(seams), seams[:4]), file=sys.stderr)
        fail = 1
if not report:
    print("check_block_seams: the run published no shot.", file=sys.stderr)
    sys.exit(2)
print("BLOCK_SEAMS=%s" % json.dumps(report, separators=(",", ":")))
sys.exit(fail)
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
echo "check_block_seams: OK (no backdrop between two blocks in any pose under ${LA_ARM_BLOCKS_UNDER_M} m)"
