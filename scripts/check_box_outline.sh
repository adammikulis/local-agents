#!/usr/bin/env bash
# THE SIMULATED BOX IS IN THE PICTURE, AND ONLY WHERE THE BOX IS. The rung-1 slice is photographed twice
# from one pose, once with the outline drawn and once with it ablated, and the two frames are compared
# against the polyline the renderer published: the ground perimeter differs, the rest of the frame does
# not, and each corner pillar has faded under its own declared floor by the fade height.
# EXIT 0 the box is drawn where the box is · 1 it is not · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_godot.sh"
. "$ROOT/scripts/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
require_tool python3

SCENE="addons/local_agents/examples/SliceRung1Demo.tscn"
[ -f "$ROOT/$SCENE" ] || { echo "check_box_outline: no scene at $SCENE" >&2; exit 2; }
# THE POSE THE FADE IS READ FROM: the one that separates a pillar's foot from its fade height by the
# most pixels, so the two discs never overlap, turned onto the two corners whose feet no relief hides.
POSE="${LA_BOX_OUTLINE_POSE:-6000:-40:180}"
SIZE="${LA_BOX_OUTLINE_SIZE:-1280x800}"
# THE FRAME IS THE WORLD, NOT THE INTERFACE: the protocol drops every panel, and this every module that
# moves on its own -- a marching arrow stripe and a falling probe differ between two launches wherever
# they stand, and the difference this gate reads must be the outline's.
STILL="vectors,test_masses"
# THE SIMULATED STEP BOTH PICTURES ARE OF: the loop halts there, so the sun and the ground are one world.
STEP="${LA_BOX_OUTLINE_STEP:-60}"

DIR="$(mktemp -d "${TMPDIR:-/tmp}/la_box_outline.XXXXXX")"
trap 'rm -rf "$DIR"' EXIT INT TERM

shoot() {  # <name> <ablations>
	LA_RUN_TIMEOUT="${LA_BOX_OUTLINE_TIMEOUT:-110}" "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
		"$SCENE" -- --sandbox "--shoot=$DIR/$1.png" "--shots=$POSE" --local-hour=12 \
		"--shoot-step=$STEP" --shoot-frames=150 "--shoot-size=$SIZE" "--ablate=$2" > "$DIR/$1.log" 2>&1
	echo $?
}

on_rc="$(shoot on "$STILL")"
off_rc="$(shoot off "$STILL,box_outline")"

for a in on off; do
	if grep -qE 'SHADER ERROR|Shader compilation failed' "$DIR/$a.log"; then
		echo "check_box_outline: the $a arm refused a shader, so its frame is of a broken renderer." >&2
		grep -m4 -E 'SHADER ERROR|Shader compilation failed|\.gdshader' "$DIR/$a.log" >&2
		exit 2
	fi
done

python3 - "$DIR" "$on_rc" "$off_rc" <<'PY'
import json, math, os, sys

try:
    from PIL import Image, ImageChops, ImageDraw
except ImportError:
    print("check_box_outline: python3 has no PIL, so no picture can be read. A gate that cannot run "
          "FAILS.", file=sys.stderr)
    sys.exit(2)

d, on_rc, off_rc = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])

# 8-bit steps a glow must clear to be in the picture at all. Below this two frames of the same world
# differ by their own rounding.
MIN_DIFF = 8
# A pixel this many drawn girths from every point of the outline is not on the outline.
FAR = 6.0
# What must be lit along the perimeter, and what may differ away from it.
GROUND_LIT = 0.6
FAR_HOT = 0.005
# Fractions of a pillar's fade height that count as its lit end.
LOW_MAX = 0.25
# Corner pillars the pose frames whole, lit end and fade height both in the picture.
PILLARS = 2


def log(name):
    return open(os.path.join(d, name + ".log"), errors="replace").read()


def shot_path(text):
    for line in text.splitlines():
        if line.startswith("SHOT_SAVED="):
            return line[len("SHOT_SAVED="):].split()[0]
    return None


on_log, off_log = log("on"), log("off")
if on_rc != 0 or off_rc != 0:
    print("check_box_outline: the arms exited %d and %d, so no pair of frames was taken."
          % (on_rc, off_rc), file=sys.stderr)
    print("\n".join(on_log.splitlines()[-20:]), file=sys.stderr)
    sys.exit(2)
if "BOX_OUTLINE_ABSENT=" in on_log:
    print("check_box_outline: the body reported no surface under the box footprint, so the ground line "
          "was never laid.", file=sys.stderr)
    sys.exit(2)

# THE LAST READING BEFORE THE SHUTTER: the eye is standing still by then, so the geometry it published
# is the geometry the photograph caught.
pub = None
for line in on_log.splitlines():
    if line.startswith("BOX_OUTLINE="):
        pub = json.loads(line[len("BOX_OUTLINE="):])
    elif line.startswith("SHOT_SAVED=") and pub is not None:
        break
if pub is None:
    print("check_box_outline: the drawn arm published no BOX_OUTLINE line, so nothing says where the "
          "box stands in the frame.", file=sys.stderr)
    sys.exit(2)

fails = []
# THE ABLATION IS REAL: --ablate=box_outline stops the module, so the dark arm publishes nothing.
if "BOX_OUTLINE=" in off_log:
    fails.append("--ablate=box_outline left the outline running: the dark arm published its geometry")

def shot_flag(text, name):
    for line in text.splitlines():
        if line.startswith("SHOT_SAVED="):
            for tok in line.split():
                if tok.startswith(name + "="):
                    return tok[len(name) + 1:]
    return None


# ONE WORLD TWICE: both frames at one simulated step, each taken once its ground was built and uncovered.
steps = (shot_flag(on_log, "sim_step"), shot_flag(off_log, "sim_step"))
if steps[0] is None or steps[0] != steps[1] or int(steps[0]) < 0:
    print("check_box_outline: the arms were shot at simulated steps %s and %s, so they are two worlds."
          % steps, file=sys.stderr)
    sys.exit(2)
for name, text in (("on", on_log), ("off", off_log)):
    if shot_flag(text, "ground_meshed") != "true":
        print("check_box_outline: the %s arm was shot before its ground was built and uncovered." % name,
              file=sys.stderr)
        sys.exit(2)

pa, pb = shot_path(on_log), shot_path(off_log)
if pa is None or pb is None:
    print("check_box_outline: an arm published no shot, so nothing was photographed.", file=sys.stderr)
    sys.exit(2)
a = Image.open(pa).convert("RGB")
b = Image.open(pb).convert("RGB")
if a.size != b.size:
    print("check_box_outline: the frames are %s and %s, so they are not the same picture."
          % (a.size, b.size), file=sys.stderr)
    sys.exit(2)
w, h = a.size
if [int(v) for v in pub["size"]] != [w, h]:
    print("check_box_outline: the outline was projected into a %s frame and the picture is %dx%d, so "
          "the polyline names other pixels." % (pub["size"], w, h), file=sys.stderr)
    sys.exit(2)
# THE DIFFERENCE, PER PIXEL: the largest channel step between the two frames.
ch = ImageChops.difference(a, b).split()
mx = ImageChops.lighter(ImageChops.lighter(ch[0], ch[1]), ch[2])

thick = max(2.0, float(pub["thick_px"]))
# A DISC ONE GIRTH ACROSS: the published point is where the line's centre runs, and the pixel carrying
# it is within the line's own drawn thickness of that.
rad = int(round(thick)) + 2


def disc_max(px, py):
    x0, y0 = int(round(px)), int(round(py))
    box = (max(x0 - rad, 0), max(y0 - rad, 0), min(x0 + rad + 1, w), min(y0 + rad + 1, h))
    if box[2] <= box[0] or box[3] <= box[1]:
        return 0
    return mx.crop(box).getextrema()[1]


def in_frame(p):
    return 0 <= p[0] < w and 0 <= p[1] < h


# THE DRAWN LINE, IN PIXELS: every published run walked pair by pair. A pair with a vertex behind the
# eye joins nothing, and the piece between two vertices is filled in so the mask follows the line and
# not a string of beads.
segments = []
for run in pub["ground"]:
    for i in range(len(run) - 1):
        if run[i] is not None and run[i + 1] is not None:
            segments.append((run[i], run[i + 1]))
for run in pub["pillars"]:
    for i in range(len(run) - 1):
        if run[i] is not None and run[i + 1] is not None:
            segments.append((run[i], run[i + 1]))
if not segments:
    print("check_box_outline: none of the outline's vertices stand in front of the eye, so the pose "
          "does not look at the box.", file=sys.stderr)
    sys.exit(2)

ground_pts = [p for run in pub["ground"] for p in run if p is not None and in_frame(p)]
if len(ground_pts) < 8:
    print("check_box_outline: only %d of the ground line's points stand in the frame, so the pose does "
          "not look at the box." % len(ground_pts), file=sys.stderr)
    sys.exit(2)

lit = [disc_max(p[0], p[1]) for p in ground_pts]
hit = sum(1 for v in lit if v >= MIN_DIFF)
frac = hit / float(len(lit))
if frac < GROUND_LIT:
    fails.append("only %d of %d points on the ground perimeter differ between the two frames (%.0f%%): "
                 "the box's edges are not on the ground" % (hit, len(lit), 100.0 * frac))

# NOT ELSEWHERE. The drawn polyline is stroked FAR girths wide; a pixel outside that stroke is off the
# box, and the frame there is the same frame twice.
reach = int(round(FAR * thick)) + rad
mask = Image.new("L", (w, h), 0)
pen = ImageDraw.Draw(mask)
for p, q in segments:
    pen.line([tuple(p), tuple(q)], fill=255, width=2 * reach + 1)
    for e in (p, q):
        pen.ellipse([e[0] - reach, e[1] - reach, e[0] + reach, e[1] + reach], fill=255)
far_total = mask.histogram()[0]
if far_total < w * h // 10:
    print("check_box_outline: the outline's neighbourhood covers all but %d pixels of the frame, so "
          "'not elsewhere' asks nothing." % far_total, file=sys.stderr)
    sys.exit(2)
hot = mx.point(lambda v: 255 if v >= MIN_DIFF else 0)
far_hot = ImageChops.subtract(hot, mask).histogram()[255]
far_frac = far_hot / float(far_total)
if far_frac > FAR_HOT:
    fails.append("%.2f%% of the frame away from the box differs between the two arms: the outline is "
                 "drawing somewhere the box is not" % (100.0 * far_frac))

# THE PILLARS FADE, READ WHERE THE POLYLINE ACTUALLY PROJECTS. Every pillar whose fade height and lit
# end both stand in the frame is measured, and one drawn nowhere there is a box missing from the picture.
# One the pose does not frame is skipped by name.
ground_segs = [(run[i], run[i + 1]) for run in pub["ground"] for i in range(len(run) - 1)
               if run[i] is not None and run[i + 1] is not None]


def off_line(p, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    span = dx * dx + dy * dy
    t = 0.0 if span == 0.0 else max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / span))
    return math.hypot(p[0] - a[0] - t * dx, p[1] - a[1] - t * dy)


# A sample within two discs of the ground line reads the ground line, not the pillar.
def clear_of_ground(p):
    return all(off_line(p, a, b) > 2 * rad for a, b in ground_segs)


floor = float(pub["fade_floor"])
at = [float(t) for t in pub["pillar_at"]]
top_i = len(at) - 1
low_i = [i for i, t in enumerate(at) if t <= LOW_MAX]
reads = []
skipped = []
for run in pub["pillars"]:
    top_px = run[top_i]
    if top_px is None or not in_frame(top_px):
        skipped.append("its fade height stands outside the frame")
        continue
    lows = [run[i] for i in low_i if run[i] is not None and in_frame(run[i])]
    clear = [p for p in lows if clear_of_ground(p)]
    if not lows:
        skipped.append("its lit end stands outside the frame")
        continue
    if not clear:
        skipped.append("its lit end stands only on the ground line")
        continue
    lit = max(disc_max(p[0], p[1]) for p in clear)
    top = disc_max(top_px[0], top_px[1])
    reads.append((lit, top))
    if lit < MIN_DIFF:
        fails.append("a corner pillar the frame holds whole is not in the picture at its lit end (%d of "
                     "255)" % lit)
    elif top > floor * lit or top >= MIN_DIFF:
        fails.append("a corner pillar still reads %d of 255 at the fade height against %d at its lit "
                     "end: over the declared floor of %.3f, or still in the picture at all"
                     % (top, lit, floor))
for why in skipped:
    print("check_box_outline: a corner pillar was not measured -- %s." % why, file=sys.stderr)
if len(reads) < PILLARS:
    print("check_box_outline: the pose frames %d corner pillar(s) whole and the fade is read on %d, so "
          "the pose does not look at the box." % (len(reads), PILLARS), file=sys.stderr)
    sys.exit(2)

print('BOX_OUTLINE_SHOT={"ground_lit":%.3f,"far_hot":%.5f,"pillars":%s,"unmeasured":%d,'
      '"thick_px":%.2f,"fade_m":%.0f}'
      % (frac, far_frac, json.dumps(reads), len(skipped), thick, float(pub["fade_m"])))
if fails:
    for f in fails:
        print("  " + f, file=sys.stderr)
    print("check_box_outline: FAIL (%d)" % len(fails))
    sys.exit(1)
print("check_box_outline: OK")
PY
