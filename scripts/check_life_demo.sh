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

LOG="$(mktemp "${TMPDIR:-/tmp}/la_life_demo.XXXXXX")"
trap 'rm -f "$LOG"' EXIT INT TERM
LA_RUN_TIMEOUT="${LA_LIFE_TIMEOUT:-110}" "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
	"$SCENE" --fixed-fps 60 -- --sandbox "--run-frames=$FRAMES" > "$LOG" 2>&1
rc=$?

python3 - "$LOG" "$rc" "$MIN_FPS" <<'PY'
import json, re, sys

log, rc, min_fps = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
text = open(log, errors="replace").read()

def last(prefix):
    hit = None
    for line in text.splitlines():
        if line.startswith(prefix):
            hit = line[len(prefix):]
    return hit

report = last("SIM_REPORT=")
pop = last("POP_TRACE=")
if report is None or pop is None:
    print("check_life_demo: the run published no %s (exit %d)."
          % ("SIM_REPORT" if report is None else "POP_TRACE", rc), file=sys.stderr)
    print("\n".join(text.splitlines()[-25:]), file=sys.stderr)
    sys.exit(2)
snap = json.loads(report)
trace = json.loads(pop)
gauges = snap.get("gauges", {})

fails = []
# NOTHING THREW. A demo that errors every frame is not a demo, whatever its counts say.
errs = [l for l in text.splitlines() if "SCRIPT ERROR" in l]
if errs:
    fails.append("the run threw %d script error(s), first: %s" % (len(errs), errs[0].strip()))

# THE WORLD SEALED. Before the seal matter may be created; a run measured inside seeding measures nothing.
if "WORLD_SEALED=" not in text:
    fails.append("the world never sealed, so nothing it did was under conservation")

# EVERY SEEDED KIND IS STILL THERE.
counts = trace.get("counts", {})
for kind in ("creatures", "plants", "trees", "fish"):
    if int(counts.get(kind, 0)) <= 0:
        fails.append("no %s are left alive at the end of the run" % kind)

# WHAT FEEDS LIFE IS A DECLARED STAND-IN, AND IT ACTUALLY FED SOMETHING. `created` is what the fake made;
# zero means either the real path is carrying it (then the record must go) or life is running on nothing.
fakes = snap.get("fakes", {})
if not isinstance(fakes, dict) or not fakes:
    fails.append("the run declared no fakes, so nothing says what is standing in for the missing rungs")
else:
    for name in ("drinking_water", "plant_carbon"):
        made = float(fakes.get(name, {}).get("created", 0.0))
        if made <= 0.0:
            fails.append("the '%s' stand-in handed nothing out, so nothing drew on it" % name)

# NO SLOW FRAME. `fps` keeps its own running minimum, so this is the worst frame the run had.
fps = gauges.get("fps", {})
worst = float(fps.get("min", 0.0)) if isinstance(fps, dict) else 0.0
if worst < min_fps:
    fails.append("the worst frame of the run fell below %g fps, which is not watchable" % min_fps)

print("LIFE_DEMO={\"kinds\":%s,\"fakes\":%s,\"sealed\":%s,\"errors\":%d}"
      % (json.dumps({k: int(counts.get(k, 0)) for k in ("creatures", "plants", "trees", "fish")}),
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
