#!/usr/bin/env bash
# A BODY'S MASS IS THE ONE INPUT AND ITS ENERGY ECONOMY IS DERIVED FROM IT. Three arms: the LAW, body
# carbon, water, basal rate, mouth rate and drinking bout against measured animal physiology in
# check_creature_energy.gd; the WORLD, a life-demo run whose booked carbon a second is the Kleiber rate
# of the animals alive to oxidise it; the CAUSE, no body dead of a process its world does not contain.
# EXIT 0 the economy is in real units * 1 it is not * 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_godot.sh"
. "$ROOT/scripts/lib_capture.sh"
require_tool python3
require_tool godot

RUNNER="$ROOT/scripts/check_creature_energy.gd"
[ -f "$RUNNER" ] || { echo "check_creature_energy: no runner at $RUNNER" >&2; exit 2; }
SCENE="addons/local_agents/examples/LifeDemo.tscn"
[ -f "$ROOT/$SCENE" ] || { echo "check_creature_energy: no scene at $SCENE" >&2; exit 2; }

# --- ARM 1: the law, with no world at all. It reads tables, so it rides the shared headless batch. ----
OUT="$(la_headless creature_energy)"
case $? in
	0) ;;
	2) exit 2 ;;
	*) OUT="$(la_godot --headless --path "$ROOT" -s "$RUNNER" 2>&1)" ;;
esac
LAW="$(printf '%s\n' "$OUT" | grep -o 'CREATURE_ENERGY=.*' | tail -n 1)"
if [ -z "$LAW" ]; then
	printf '%s\n' "$OUT" | tail -25 >&2
	echo "check_creature_energy: the runner published no CREATURE_ENERGY marker; nothing was checked." >&2
	exit 2
fi
printf '%s\n' "$OUT" | grep '^  ' >&2 || true
echo "$LAW"
LAW_FAILS="$(printf '%s\n' "$LAW" | sed -n 's/.*"failures":\([0-9][0-9]*\).*/\1/p')"
case "$LAW_FAILS" in "" | *[!0-9]*) echo "check_creature_energy: the marker carries no failure count." >&2; exit 2 ;; esac

# --- ARM 2: the world. FIXED FPS AND NO LA_EVO_FAST, so simulated seconds are frames over fps. --------
# ONE LIFE RUN PER LINT: the shared arm records it and publishes the frames and fps it ran at.
FRAMES="${LA_ENERGY_FRAMES:-300}"
FPS=60
LOG="$(la_cap_life_log)"
case $? in
	0)
		rc="$(la_cap_life rc)"
		FRAMES="$(la_cap_life frames)"
		FPS="$(la_cap_life fps)"
		;;
	2) exit 2 ;;
	*)
		LOG="${LA_ENERGY_LOG:-$(mktemp "${TMPDIR:-/tmp}/la_creature_energy.XXXXXX")}"
		[ -n "${LA_ENERGY_LOG:-}" ] || trap 'rm -f "$LOG"' EXIT INT TERM
		LA_RUN_TIMEOUT="${LA_ENERGY_TIMEOUT:-110}" LA_EVO_FAST= "$ROOT/scripts/run_sim_offscreen.sh" \
			--path "$ROOT" "$SCENE" --fixed-fps "$FPS" -- --sandbox "--run-frames=$FRAMES" > "$LOG" 2>&1
		rc=$?
		;;
esac
case "$FRAMES$FPS" in "" | *[!0-9]*) echo "check_creature_energy: the life arm published no frames or fps." >&2; exit 2 ;; esac

python3 - "$LOG" "$rc" "$FRAMES" "$FPS" "$LAW_FAILS" <<'PY'
import json, math, re, sys

log, rc, frames, fps, law_fails = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]), int(sys.argv[5])
text = open(log, errors="replace").read()

def load(prefix, what):
    got = [l[len(prefix):] for l in text.splitlines() if l.startswith(prefix)]
    if not got:
        print("check_creature_energy: the run published no %s (exit %d)." % (what, rc), file=sys.stderr)
        print("\n".join(text.splitlines()[-25:]), file=sys.stderr)
        sys.exit(2)
    try:
        return json.loads(re.sub(r"(?<![\w.])-?(nan|inf)(?![\w.])", "null", got[-1]))
    except ValueError as e:
        print("check_creature_energy: the %s line is not readable: %s" % (what, e), file=sys.stderr)
        sys.exit(2)

snap = load("SIM_REPORT=", "SIM_REPORT")
if not snap.get("world_sealed"):
    print("check_creature_energy: the world never sealed, so nothing it did was under conservation.",
          file=sys.stderr)
    sys.exit(2)

# KLEIBER AND THE OXIDATION, RESTATED HERE. The same two published facts arm 1 holds the code to, so
# this arm compares the run against the world rather than against the code that produced it.
KLEIBER_W_AT_1KG = 70.0 * 4184.0 / 86400.0
KLEIBER_EXPONENT = 0.75
# The heat of oxidising a mole of organic carbon bounds the moles a watt buys, so the widest band the
# measured enthalpy allows is the one used here.
CARBON_J_LO, CARBON_J_HI = 3.9e5, 4.8e5
# A body oxidises between the rate of a sleeping animal (this physiology halves the demand at rest) and
# its factorial aerobic scope. Nothing outside that is an animal breathing.
REST_SCOPE, MAX_SCOPE = 0.5, 10.0

metab = snap.get("metab")
if not isinstance(metab, dict) or not metab:
    print("check_creature_energy: the run reported no per-species metabolism, so no body was weighed.",
          file=sys.stderr)
    sys.exit(2)
fakes = snap.get("fakes") or {}
o2 = fakes.get("breathable_o2") or {}

fails = []
# THE STAND-IN ACTUALLY BREATHED. With no free O2 in the seeded air, every mole a body oxidises comes
# from this record; zero draws is a population that never respired at all, which is the state this gate
# exists to refuse.
if int(o2.get("draws", 0)) <= 0:
    fails.append("the 'breathable_o2' stand-in was never drawn on, so no body oxidised any carbon")

alive = 0.0
demand_mol_s = 0.0      # the Kleiber rate of the animals alive at the end, moles of carbon a second
for sp, row in metab.items():
    n = float(row.get("n", 0))
    m = float(row.get("mass", 0.0))
    if n <= 0.0 or m <= 0.0:
        continue
    alive += n
    demand_mol_s += n * KLEIBER_W_AT_1KG * math.pow(m, KLEIBER_EXPONENT)
if alive <= 0.0 or demand_mol_s <= 0.0:
    print("check_creature_energy: the run ended with no weighed body, so nothing could be compared.",
          file=sys.stderr)
    sys.exit(2)

# EVERY BODY THAT EVER LIVED IN THIS RUN. Animals died over it, so what was booked was produced by a
# population between the count at the end and the count of everything ever booked into being.
spawned = float((fakes.get("founding_stock") or {}).get("draws", 0)) or alive
seconds = frames / fps
booked = float(o2.get("created", 0.0)) + float(snap.get("biota_co2_out", 0.0))
rate = booked / seconds

lo = REST_SCOPE * demand_mol_s / CARBON_J_HI
hi = MAX_SCOPE * (spawned / alive) * demand_mol_s / CARBON_J_LO
if not (lo <= rate <= hi):
    fails.append("bodies booked %.6g mol of carbon a second; %d-%d animals at Kleiber's rate oxidise "
                 "%.6g to %.6g" % (rate, int(alive), int(spawned), lo, hi))

# A death cannot name a process absent from its world.
def absent_death_processes(report):
    out = []
    for cause, live_key in {"burned": "fire_live"}.items():
        n = int((report.get("events") or {}).get("death/%s" % cause, 0))
        if n > 0 and not report.get(live_key):
            out.append("%d bodies died '%s' without %s" % (n, cause, live_key))
    return out

if not absent_death_processes({"events": {"death/burned": 1}, "fire_live": False}) \
        or absent_death_processes({"events": {"death/burned": 1}, "fire_live": True}) \
        or absent_death_processes({"events": {}, "fire_live": False}):
    fails.append("death process controls failed")
fails.extend(absent_death_processes(snap))
events = snap.get("events") or {}

print("CREATURE_ENERGY_WORLD={\"alive\":%d,\"spawned\":%d,\"seconds\":%g,\"o2_draws\":%d,\"causes\":%s}"
      % (int(alive), int(spawned), seconds, int(o2.get("draws", 0)),
         json.dumps({k[6:]: int(v) for k, v in sorted(events.items())
                     if k.startswith("death/") and ":" not in k})))
if rc != 0:
    fails.append("the run exited %d" % rc)
if law_fails:
    fails.append("%d physiology bound(s) fell outside measured animal values" % law_fails)
if fails:
    for f in fails:
        print("  " + f, file=sys.stderr)
    print("check_creature_energy: FAIL (%d)" % len(fails))
    sys.exit(1)
print("check_creature_energy: OK")
PY
