#!/usr/bin/env bash
# NOTHING A LIVING THING DOES CREATES OR DESTROYS MATTER AFTER THE SEAL. A life-full slice runs at the
# playable rung; every biota channel the device booked as created or removed equals what the seam's body
# stock moved to or from it, and matter a stand-in made goes home to that stand-in instead of into the
# sealed field. The bound is float32 round-off over the seam's own edit count, not a chosen tolerance.
# EXIT 0 the books close * 1 they do not * 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_capture.sh"
require_tool python3

SCENE="addons/local_agents/examples/LifeDemo.tscn"
[ -f "$ROOT/$SCENE" ] || { echo "check_biota_books: no scene at $SCENE" >&2; exit 2; }
FRAMES="${LA_BIOTA_FRAMES:-300}"

# ONE LIFE RUN PER LINT. The shared arm records it; this gate only reads what its books did.
LOG="$(la_cap_life_log)"
case $? in
	0) rc="$(la_cap_life rc)" ;;
	2) exit 2 ;;
	*)
		LOG="${LA_BIOTA_LOG:-$(mktemp "${TMPDIR:-/tmp}/la_biota_books.XXXXXX")}"
		[ -n "${LA_BIOTA_LOG:-}" ] || trap 'rm -f "$LOG"' EXIT INT TERM
		LA_RUN_TIMEOUT="${LA_BIOTA_TIMEOUT:-110}" LA_EVO_FAST= "$ROOT/scripts/run_sim_offscreen.sh" \
			--path "$ROOT" "$SCENE" --fixed-fps 60 -- --sandbox "--run-frames=$FRAMES" > "$LOG" 2>&1
		rc=$?
		;;
esac

python3 - "$LOG" "$rc" <<'PY'
import json, re, sys

log, rc = sys.argv[1], int(sys.argv[2])
text = open(log, errors="replace").read()

def last(prefix):
    got = [l[len(prefix):] for l in text.splitlines() if l.startswith(prefix)]
    return got[-1] if got else None

line = last("SIM_REPORT=")
if line is None:
    print("check_biota_books: the run published no SIM_REPORT (exit %d)." % rc, file=sys.stderr)
    print("\n".join(text.splitlines()[-25:]), file=sys.stderr)
    sys.exit(2)
try:
    snap = json.loads(re.sub(r"(?<![\w.])-?(nan|inf)(?![\w.])", "null", line))
except ValueError as e:
    print("check_biota_books: the SIM_REPORT line is not readable: %s" % e, file=sys.stderr)
    sys.exit(2)

if not snap.get("world_sealed"):
    print("check_biota_books: the world never sealed, so nothing it did was under conservation.",
          file=sys.stderr)
    sys.exit(2)

def num(key):
    v = snap.get(key)
    return float(v) if isinstance(v, (int, float)) else 0.0

fakes = snap.get("fakes")
if not isinstance(fakes, dict) or not fakes:
    print("check_biota_books: the run declared no stand-ins, so nothing says what carried life.",
          file=sys.stderr)
    sys.exit(2)

# NOTHING LIVED, NOTHING TO WEIGH. A world with no bodies cannot answer what a body's matter did.
pop = last("POP_TRACE=")
alive = 0
if pop is not None:
    try:
        clean = re.sub(r"(?<![\w.])-?(nan|inf)(?![\w.])", "null", pop)
        alive = int((json.loads(clean).get("counts") or {}).get("creatures", 0))
    except ValueError:
        alive = 0
if alive <= 0:
    print("check_biota_books: the run held no creature, so the body books were never exercised.",
          file=sys.stderr)
    sys.exit(2)
returned = sum(float(f.get("returned", 0.0)) for f in fakes.values())

# Relative round-off of a sum of this many float32 values: the format's epsilon times the count. A
# property of IEEE-754 binary32, not a tolerance anybody chose.
FLOAT32_EPSILON = 1.0 / 16777216.0
rel = max(int(num("biota_exchanges")), 1) * FLOAT32_EPSILON

fails = []

def same(what, a_key, b_key):
    a, b = num(a_key), num(b_key)
    if abs(a - b) > rel * max(abs(a), abs(b)):
        fails.append("%s: %s=%r and %s=%r are not the same crossing" % (what, a_key, a, b_key, b))

def zero(key, why):
    if num(key) != 0.0:
        fails.append("%s is %r, not zero: %s" % (key, num(key), why))

# RESPIRATION IS A TRANSFORMATION. One mole of the head cell's O2 becomes one mole of CO2 in place, so
# neither side is sourceless and neither is a sink; the carbon is the body's.
zero("inject_created_co2", "respiration credited CO2 the body did not pay carbon for")
zero("inject_removed_o2", "respiration destroyed oxygen instead of turning it into CO2")
# A body is not a source or a sink of these at all.
for key in ("inject_created_o2", "inject_created_biomass", "inject_removed_co2",
            "inject_removed_detritus", "inject_removed_org_h", "inject_removed_org_o",
            "inject_created_fuel", "inject_removed_fuel"):
    zero(key, "no body puts matter into or takes it out of that channel")

# WHAT THE DEVICE APPLIED IS WHAT THE STOCK MOVED. The seam books each crossing on the CPU against a body
# stock; the device books what it applied to the field. They are the same crossing seen twice.
same("grazing", "inject_removed_biomass", "biota_graze_taken")
same("drinking", "inject_removed_h2o", "biota_water_in")
same("transpiration", "inject_created_h2o", "biota_water_out")
same("litter", "inject_created_detritus", "biota_detritus_out")
same("respiration", "inject_moved_o2", "biota_co2_out")

# A BODY NEVER HANDS BACK WHAT IT NEVER HELD. A negative element in the stock is a field credit no body
# paid for.
elements = sorted(k[len("biota_stock_"):] for k in snap if k.startswith("biota_stock_"))
for el in elements:
    if num("biota_stock_" + el) < -rel * max(abs(num("biota_stock_" + el)), 1.0):
        fails.append("the %s body stock is negative: bodies handed the field matter they never held" % el)

# EVERY BODY THAT APPEARED AFTER THE SEAL WAS BOOKED. There is no field for it to build itself out of,
# so the founding stand-in makes its elements and says how much. This is also the positive control: with
# no body booked, the zeroes above would be the zeroes of a seam nothing ever called.
founding = fakes.get("founding_stock") or {}
if float(founding.get("created", 0.0)) <= 0.0 or int(founding.get("draws", 0)) <= 0:
    fails.append("%d creature(s) lived and none was booked against the 'founding_stock' stand-in, so "
                 "bodies arrived after the seal with nothing paying for them" % alive)

# CREATION AFTER THE SEAL IS REFUSED, NOT LOGGED.
refused = snap.get("creation_after_seal") or {}
if refused:
    fails.append("creation_after_seal names %s" % ", ".join(sorted(refused)))

print("BIOTA_BOOKS={\"edits\":%d,\"elements\":%s,\"handed_back\":%s}"
      % (int(num("biota_exchanges")), json.dumps(elements), json.dumps(returned > 0.0)))
if rc != 0:
    fails.append("the run exited %d" % rc)
if fails:
    for f in fails:
        print("  " + f, file=sys.stderr)
    print("check_biota_books: FAIL (%d)" % len(fails))
    sys.exit(1)
print("check_biota_books: OK")
PY
