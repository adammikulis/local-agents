#!/usr/bin/env bash
# A TEST MASS RELEASED OVER THE SLICE FALLS THE WAY A MASS FALLS: t = sqrt(2h/g) and v = sqrt(2gh) for
# the RADIAL drop h and the g it was released in, within 1% -- g's own change over the drop (2h/R) and
# the centrifugal term (w^2 R / g) are each under a percent here -- and it stops inside the field box.
# CONTROLS: a world with no solved gravity offers no probe and no glyphs, and drops nothing.
# EXIT 0 the probe fell as a mass falls - 1 it did not - 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_godot.sh"
. "$ROOT/scripts/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
require_tool python3

BOUND="${LA_TEST_MASS_BOUND:-0.01}"
RUNG1="addons/local_agents/examples/SliceRung1Demo.tscn"
RUNG0="addons/local_agents/game/VoxelWorld.tscn"
BOX="0,surface,0,3,24,3,5120,10"
for f in "$RUNG1" "$RUNG0"; do
	[ -f "$ROOT/$f" ] || { echo "check_test_mass: no scene at $f" >&2; exit 2; }
done

SHOTS="$(mktemp -d "${TMPDIR:-/tmp}/la_test_mass.XXXXXX")"
FELL="$(mktemp "${TMPDIR:-/tmp}/la_test_mass_fell.XXXXXX")"
DRY="$(mktemp "${TMPDIR:-/tmp}/la_test_mass_dry.XXXXXX")"
trap 'rm -rf "$SHOTS" "$FELL" "$DRY"' EXIT INT TERM

# ARM 1 - the rung-1 demo, photographed so the run also publishes what the glyph renderer drew.
LA_RUN_TIMEOUT="${LA_TEST_MASS_TIMEOUT:-110}" "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
	"$RUNG1" -- --sandbox "--shoot=$SHOTS/shot.png" "--shots=200:-15:0" \
	--shoot-frames=150 --shoot-size=640x400 > "$FELL" 2>&1
fell_rc=$?

# ARM 2 - the same box at the rung below, asking for the same probe and the same glyphs.
LA_SLICE_BOX="$BOX" LA_RUN_TIMEOUT="${LA_TEST_MASS_TIMEOUT:-110}" \
	"$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" "$RUNG0" -- --sandbox --ui --rung=0 \
	--vectors=gravity --planet-only --run-frames=30 > "$DRY" 2>&1
dry_rc=$?

python3 - "$FELL" "$DRY" "$fell_rc" "$dry_rc" "$BOUND" <<'PY'
import json, math, re, sys

fell_log, dry_log, fell_rc, dry_rc, bound = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5])
fell = open(fell_log, errors="replace").read()
dry = open(dry_log, errors="replace").read()


def line(text, prefix):
    got = [l[len(prefix):] for l in text.splitlines() if l.startswith(prefix)]
    return got[-1] if got else None


landed = line(fell, "TEST_MASS_LANDED=")
if landed is None:
    print("check_test_mass: the rung-1 run dropped no probe that reached the ground (exit %d), so the"
          % fell_rc, file=sys.stderr)
    print("                 fall went unmeasured. Refusing to report a pass.", file=sys.stderr)
    print("\n".join(fell.splitlines()[-20:]), file=sys.stderr)
    sys.exit(2)
row = json.loads(landed)
shot = line(fell, "SHOT_SAVED=")
arrows = int(re.search(r"field_arrows=(\d+)", shot).group(1)) if shot and "field_arrows=" in shot else -1

h = float(row["height_m"])
g = float(row["g_release"])
t = float(row["time"])
v = float(row["speed"])
fails = []
if not (h > 0.0 and g > 0.0):
    print("check_test_mass: the probe reports height %r in gravity %r, so there is nothing to check "
          "against." % (h, g), file=sys.stderr)
    sys.exit(2)
t_free = math.sqrt(2.0 * h / g)
v_free = math.sqrt(2.0 * g * h)
t_rel = abs(t - t_free) / t_free
v_rel = abs(v - v_free) / v_free
if t_rel > bound:
    fails.append("it fell for %.4g s where sqrt(2h/g) is %.4g s" % (t, t_free))
if v_rel > bound:
    fails.append("it landed at %.4g m/s where sqrt(2gh) is %.4g m/s" % (v, v_free))
if int(row.get("cell", -1)) < 0:
    fails.append("it stopped outside the field box, so it landed on a declared radius and not on rock")
if arrows <= 0:
    fails.append("the run drew %d gravity glyphs, so the field the probe fell through was never shown"
                 % arrows)
if "FIELD_VECTORS_ABSENT=" in fell:
    fails.append("the rung-1 run reported its own gravity field absent")
if "TEST_MASS_REFUSED=" in fell:
    fails.append("the rung-1 run refused the probe it then dropped")
if fell_rc != 0:
    fails.append("the rung-1 run exited %d" % fell_rc)

# THE CONTROLS. Rung 0 solves no potential: it offers no probe and no glyphs, and drops nothing.
if "TEST_MASS_REFUSED=" not in dry:
    fails.append("the rung-0 world did not refuse the probe, so the refusal cannot fail either")
if "FIELD_VECTORS_ABSENT=" not in dry:
    fails.append("the rung-0 world drew gravity glyphs for a field it does not solve")
if "TEST_MASS_LANDED=" in dry:
    fails.append("the rung-0 world landed a probe it never released")
if dry_rc != 0:
    fails.append("the rung-0 run exited %d" % dry_rc)

print('TEST_MASS={"height_m":%.1f,"g_release":%.4f,"fall_rel":%.2e,"speed_rel":%.2e,"cell":%d,'
      '"glyphs":%d,"refused_below":%s}'
      % (h, g, t_rel, v_rel, int(row.get("cell", -1)), arrows,
         str("TEST_MASS_REFUSED=" in dry).lower()))
if fails:
    for f in fails:
        print("  " + f, file=sys.stderr)
    print("check_test_mass: FAIL (%d)" % len(fails))
    sys.exit(1)
print("check_test_mass: OK")
PY
