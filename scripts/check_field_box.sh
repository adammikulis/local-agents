#!/usr/bin/env bash
# THE FIELD BOX IS A WORLD. BoxFieldDemo at its own rung seeds the gas it declares at the temperature and
# pressure it declares, every cell finite, seals having created nothing after, steps on its own loop, warms
# the cells its hotplate heats, and its books close on the heat the hotplate handed in.
# EXIT 0 it is * 1 it is not * 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_godot.sh"
require_tool python3

SCENE="addons/local_agents/examples/BoxFieldDemo.tscn"
DERIVE="$ROOT/addons/local_agents/sim/material/kernels3d/state_derive.glsl"
[ -f "$ROOT/$SCENE" ] || { echo "check_field_box: no scene at $SCENE" >&2; exit 2; }
# The derive's own convergence bound on a cell's (T, p): the closest a seeded state can read back.
TOL="$(sed -n 's/^const float LA_STATE_TOL = \([0-9.eE+-]*\);.*/\1/p' "$DERIVE" | head -1)"
[ -n "$TOL" ] || { echo "check_field_box: state_derive.glsl declares no LA_STATE_TOL." >&2; exit 2; }
STEPS="${LA_FIELD_BOX_STEPS:-12}"

LOG="$(mktemp "${TMPDIR:-/tmp}/la_field_box.XXXXXX")"
trap 'rm -f "$LOG"' EXIT INT TERM
LA_RUN_TIMEOUT="${LA_FIELD_BOX_TIMEOUT:-110}" "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" "$SCENE" \
	-- "--run-frames=$STEPS" > "$LOG" 2>&1
rc=$?

python3 - "$LOG" "$rc" "$STEPS" "$TOL" <<'PY'
import json, re, sys

log, rc, steps, tol = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
text = open(log, errors="replace").read()
ULP = 2.0 ** -24


def last(prefix):
    got = [l[len(prefix):] for l in text.splitlines() if l.startswith(prefix)]
    return got[-1] if got else None


def load(line):
    return json.loads(re.sub(r"(?<![\w.])-?(nan|inf)(?![\w.])", "null", line))


stopped = last("RUN_FAILED=")
line = last("BOX_FIELD_REPORT=")
if line is None:
    print("check_field_box: the run published no BOX_FIELD_REPORT (exit %d)." % rc, file=sys.stderr)
    print("\n".join(text.splitlines()[-20:]), file=sys.stderr)
    sys.exit(2)
r = load(line)
fails = []
if stopped is not None:
    fails.append("the loop stopped: %s" % stopped)
errs = [l for l in text.splitlines() if "SCRIPT ERROR" in l or l.startswith("ERROR:")]
if errs:
    fails.append("the run logged %d error(s), first: %s" % (len(errs), errs[0].strip()))
if int(r.get("steps") or 0) < steps:
    fails.append("the box stands at step %s of the %d it was run for" % (r.get("steps"), steps))
if r.get("world_sealed") is not True:
    fails.append("the box never sealed, so nothing it did was under conservation")
if r.get("creation_after_seal"):
    fails.append("the box created after the seal: %s" % r.get("creation_after_seal"))
if r.get("nonfinite"):
    fails.append("channels holding a non-finite cell: %s" % ", ".join(r["nonfinite"]))

# WHAT THE SEED CREATED IS WHAT THE BOX DECLARED: each gas at its declared share of the gas declared.
fill = r.get("fill") or {}
x = fill.get("mole_fractions") or {}
created = r.get("world_created") or {}
gas = sum(float(created.get("seed_" + g) or 0.0) for g in x)
if not x or not gas > 0.0:
    fails.append("the box declared no gas, or its seed created none")
for g, xg in x.items():
    share = float(created.get("seed_" + g) or 0.0) / gas if gas > 0.0 else 0.0
    if abs(share - float(xg)) > 4.0 * ULP * max(float(xg), share):
        fails.append("%s is %.9g of the gas the seed created, and %.9g of the gas declared" % (g, share, xg))
if not isinstance(created.get("seed_energy_j"), (int, float)) or created.get("seed_energy_j") == 0.0:
    fails.append("the seed declared no energy")

# THE SEEDED STATE IS THE DECLARED ONE where the hotplate never reached: the top cell of the box.
seed_c, top_c, p = r.get("seed_c"), r.get("top_c"), fill.get("pressure_pa")
top_pa, source_c = r.get("top_pa"), r.get("source_c")
if None in (seed_c, top_c, p, top_pa, source_c):
    fails.append("the report carries no seed or cell state: seed_c %s, top_c %s, top_pa %s, source_c %s"
                 % (seed_c, top_c, top_pa, source_c))
else:
    t_bound = tol * max(abs(seed_c), 1.0) + 4.0 * ULP * (abs(seed_c) + 273.15)
    if abs(top_c - seed_c) > t_bound:
        fails.append("the top cell stands at %.9g C against the %.9g C declared" % (top_c, seed_c))
    if abs(top_pa - p) > (tol + 4.0 * ULP) * p:
        fails.append("the top cell stands at %.9g Pa against the %.9g Pa declared" % (top_pa, p))
    if not (r.get("inject_energy_j") or 0.0) > 0.0:
        fails.append("the hotplate handed the box no heat")
    elif not source_c - seed_c > t_bound:
        fails.append("the hotplate's cell stands at %.9g C, no warmer than the seed" % source_c)

# THE BOOKS CLOSE: every conserved quantity's worst excursion inside the round-off its own sum carries.
cons = r.get("conservation")
worst = r.get("conservation_worst") or {}
allowed = r.get("conservation_allowed_rel") or {}
if not isinstance(cons, dict) or "energy_held" not in worst:
    fails.append("the box published no books, or no energy book")
if r.get("conservation_unmeasured"):
    fails.append("books left unmeasured: %s" % r["conservation_unmeasured"])
for key, w in sorted(worst.items()):
    if not (isinstance(w, (int, float)) and abs(w) <= float(allowed.get(key, -1.0))):
        fails.append("%s drifted %s of what it holds, past the %s its round-off allows" % (key, w, allowed.get(key)))

if fails:
    print("check_field_box: FAILED", file=sys.stderr)
    for f in fails:
        print("  - " + f, file=sys.stderr)
    sys.exit(1)
print("check_field_box: OK (%d steps, sealed, %d gases at their declared shares, books closed on %s J)"
      % (int(r["steps"]), len(x), r.get("inject_energy_j")))
PY
