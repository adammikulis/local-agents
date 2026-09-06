#!/usr/bin/env bash
# THE LIFE DEMO RUNS, AND WHAT KEEPS IT ALIVE IS DECLARED. Every seeded kind is still there at the end,
# nothing throws, the worst frame is still watchable, and what feeds life is an LAFakes record that
# actually handed something out - a creature fed by a hidden constant reads like one fed by physics.
# DECISION: "playable" is every frame inside 1/30 s. EXIT 0 it lives * 1 it does not * 2 cannot run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_godot.sh"
require_tool python3

SCENE="addons/local_agents/examples/LifeDemo.tscn"
[ -f "$ROOT/$SCENE" ] || { echo "check_life_demo: no scene at $SCENE" >&2; exit 2; }
[ -f "$ROOT/addons/local_agents/examples/demos/life.tres" ] || { echo "check_life_demo: no demo entry for the scene" >&2; exit 2; }
FRAMES="${LA_LIFE_FRAMES:-300}"
MIN_FPS="${LA_LIFE_MIN_FPS:-30}"

LOG="${LA_LIFE_LOG:-$(mktemp "${TMPDIR:-/tmp}/la_life_demo.XXXXXX")}"
[ -n "${LA_LIFE_LOG:-}" ] || trap 'rm -f "$LOG"' EXIT INT TERM
LA_RUN_TIMEOUT="${LA_LIFE_TIMEOUT:-110}" "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
	"$SCENE" --fixed-fps 60 -- --sandbox "--run-frames=$FRAMES" > "$LOG" 2>&1
rc=$?

python3 - "$LOG" "$rc" "$MIN_FPS" <<'PY'
import json, re, sys

log, rc, min_fps = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
text = open(log, errors="replace").read()

def every(prefix):
    return [l[len(prefix):] for l in text.splitlines() if l.startswith(prefix)]

def last(prefix):
    got = every(prefix)
    return got[-1] if got else None

report = last("SIM_REPORT=")
pops = every("POP_TRACE=")
pop = pops[-1] if pops else None
placed = last("LIFE_IN_BOX=")
if placed is None:
    print("check_life_demo: the run published no LIFE_IN_BOX, so where it put life went unmeasured.",
          file=sys.stderr)
    print("\n".join(text.splitlines()[-25:]), file=sys.stderr)
    sys.exit(2)
if report is None or pop is None:
    print("check_life_demo: the run published no %s (exit %d)."
          % ("SIM_REPORT" if report is None else "POP_TRACE", rc), file=sys.stderr)
    print("\n".join(text.splitlines()[-25:]), file=sys.stderr)
    sys.exit(2)
# The run prints its own numbers, and a gauge that went non-finite prints as `nan`, which is not JSON.
def load(line, what):
    try:
        return json.loads(re.sub(r"(?<![\\w.])-?(nan|inf)(?![\\w.])", "null", line))
    except ValueError as e:
        print("check_life_demo: the run's %s line is not readable: %s" % (what, e), file=sys.stderr)
        print(line[:400], file=sys.stderr)
        sys.exit(2)

snap = load(report, "SIM_REPORT")
trace = load(pop, "POP_TRACE")
box = load(placed, "LIFE_IN_BOX")
gauges = snap.get("gauges", {})

fails = []
# EVERY LIVING THING STANDS WHERE THE FIELD STEPS MATTER. Outside the box no cell answers, so the
# temperature it stands in and the food at its feet are unmeasured and nothing the substrate does reaches
# it. An empty seeding is not a pass: a world that placed nothing measured nothing.
if int(box.get("out", -1)) != 0 or int(box.get("in", 0)) <= 0:
    fails.append("the seeding put %s living thing(s) outside the field box and %s inside it"
                 % (box.get("out"), box.get("in")))
# NOTHING THREW. A demo that errors every frame is not a demo, whatever its counts say.
errs = [l for l in text.splitlines() if "SCRIPT ERROR" in l]
if errs:
    fails.append("the run threw %d script error(s), first: %s" % (len(errs), errs[0].strip()))

# THE WORLD SEALED. Before the seal matter may be created; a run measured inside seeding measures nothing.
if "WORLD_SEALED=" not in text:
    fails.append("the world never sealed, so nothing it did was under conservation")

# EVERY SEEDED KIND IS STILL THERE. What the world seeded is what its first trace counted, so a kind
# this site has no room for (fish, where the box holds no open sea) is not demanded of it, and a kind it
# did seed may not go to zero.
counts = trace.get("counts", {})
first = load(pops[0], "POP_TRACE").get("counts", {})
seeded = [k for k, n in first.items() if int(n) > 0]
for kind in seeded:
    if int(counts.get(kind, 0)) <= 0:
        fails.append("the run seeded %s and none are left alive at the end" % kind)
for kind in ("creatures", "plants", "trees"):
    if int(first.get(kind, 0)) <= 0:
        fails.append("the world seeded no %s at all, so there is no demo to look at" % kind)

# WHAT FEEDS LIFE IS A DECLARED STAND-IN, AND IT ACTUALLY FED SOMETHING. `created` is what the fake made;
# zero means either the real path is carrying it (then the record must go) or life is running on nothing.
fakes = snap.get("fakes", {})
if not isinstance(fakes, dict) or not fakes:
    fails.append("the run declared no fakes, so nothing says what is standing in for the missing rungs")
else:
    # A plant draws carbon every step it grows. Water is not asked for: an animal with a full store
    # does not drink, and a run shorter than its thirst is no evidence of a broken stand-in.
    if float(fakes.get("plant_carbon", {}).get("created", 0.0)) <= 0.0:
        fails.append("the 'plant_carbon' stand-in handed nothing out, so nothing grew on it")

# NOTHING DIED OF A STAND-IN. While `drinking_water` is in force there is a drink wherever an animal
# stands, so a death by thirst means the fake never reached it and the demo is killing life with its
# own scaffolding.
if "drinking_water" in fakes:
    thirst = int(snap.get("events", {}).get("death/thirst", 0))
    if thirst > 0:
        fails.append("creatures died of thirst while the 'drinking_water' stand-in was in force")

# NO SLOW FRAME. `fps` keeps its own running minimum, so this is the worst frame the run had.
fps = gauges.get("fps", {})
worst = float(fps.get("min", 0.0)) if isinstance(fps, dict) else 0.0
if worst < min_fps:
    fails.append("the worst frame of the run fell below %g fps, which is not watchable" % min_fps)

print("LIFE_DEMO={\"kinds\":%s,\"in_box\":%s,\"outside_box\":%s,\"fakes\":%s,\"sealed\":%s,\"errors\":%d}"
      % (json.dumps({k: int(counts.get(k, 0)) for k in ("creatures", "plants", "trees", "fish")}),
         box.get("in"), box.get("out"),
         json.dumps(sorted(fakes.keys())), str("WORLD_SEALED=" in text).lower(), len(errs)))
if rc != 0:
    fails.append("the run exited %d" % rc)
if fails:
    for f in fails:
        print("  " + f, file=sys.stderr)
    print("check_life_demo: FAIL (%d)" % len(fails))
    sys.exit(1)
print("check_life_demo: OK")
PY
