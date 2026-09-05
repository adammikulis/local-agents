#!/usr/bin/env bash
# THE SAME SEED MUST GIVE THE SAME PLANET. Two runs, one seed, one length -> diff every conserved total.
#
# Not in `lint` (four windowed runs, minutes). TWO ARMS: a run drawing nothing agrees with itself
# however broken the streams are, so the second brings a rock in. POSITIVE CONTROL: it must draw MORE
# from the planet stream. It compares EVERY reading the report publishes, because a conserved total is
# invariant under WHERE a thing happened. What it separates, so the gate names the fix:
#   HORIZON  the runs covered different simulated time. --run-frames counts steps, so this is the loop.
#   RNG      the seeded streams drew different values. Reported per domain from RNG_TRACE.
#   SUBSTRATE  same horizon, same RNG draws, a different reading -> the step is order-dependent.
#
# Usage:  scripts/check_determinism.sh [--path DIR] [--frames N] [--seed N]
# Exit 0 identical · 1 the runs disagree · 2 the gate could not run (never a silent pass).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_require.sh
source "$SCRIPT_DIR/lib_require.sh"
require_tool python3
require_tool godot

PROJ="."
# 240 so frame 180 lands inside the run: RNG_TRACE is emitted every 180 frames, and without it the gate
# cannot tell an RNG divergence from a substrate one. The event arm's arrival lands well before it.
FRAMES=240
SEED=4242
while [ $# -gt 0 ]; do
  case "$1" in
    --path) PROJ="$2"; shift 2 ;;
    --frames) FRAMES="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

QA="$(mktemp "${TMPDIR:-/tmp}/la_det_qa.XXXXXX")"
QB="$(mktemp "${TMPDIR:-/tmp}/la_det_qb.XXXXXX")"
EA="$(mktemp "${TMPDIR:-/tmp}/la_det_ea.XXXXXX")"
EB="$(mktemp "${TMPDIR:-/tmp}/la_det_eb.XXXXXX")"
trap 'rm -f "$QA" "$QB" "$EA" "$EB"' EXIT

run_one() {
  local out="$1"
  shift
  # SOAK: four full runs compared end to end; run by hand, no lane blocks on it
  LA_RUN_TIMEOUT="${LA_RUN_TIMEOUT:-900}" LA_RNG_TRACE=1 \
    "$SCRIPT_DIR/run_sim_offscreen.sh" --path "$PROJ" \
    addons/local_agents/game/VoxelWorld.tscn --fixed-fps 60 \
    -- --sandbox --planet-only "--run-frames=${FRAMES}" "--seed=${SEED}" --no-fauna "$@" \
    > "$out" 2>&1
  return 0
}

echo "check_determinism: quiet arm x2 then event arm x2, ${FRAMES} frames, seed ${SEED}" >&2
run_one "$QA"
run_one "$QB"
run_one "$EA" --auto-meteor
run_one "$EB" --auto-meteor

python3 - "$QA" "$QB" "$EA" "$EB" <<'PY'
import json, re, sys

# The horizon decides whether anything else is comparable, so it is checked first and separately.
HORIZON = ("field_step", "field_sim_s")
# Readings OF THE HOST, not of the world: wall-clock costs, the frame rate they imply, driver memory.
HOST = re.compile(r"(^|\.)(fps|video_mem_MB)(\.|$)|_ms(\.|$)")
# The stream an arriving rock draws its size and approach from.
EVENT_DOMAIN = "planet"
MAX_SHOWN = 12


def load(path):
    report, traces = None, []
    for line in open(path, errors="replace"):
        if line.startswith("SIM_REPORT="):
            report = line[11:]
        elif line.startswith("RNG_TRACE="):
            traces.append(line[10:].strip())
    return (json.loads(report) if report else None), traces


def flat(d, prefix=""):
    out = {}
    for k, v in d.items():
        key = prefix + str(k)
        if isinstance(v, dict):
            out.update(flat(v, key + "."))
        else:
            out[key] = v
    return out


# None only when the run published no trace at all. A run that traced and never touched the stream
# drew zero from it, which is exactly what the quiet arm is supposed to read.
def planet_draws(traces):
    seen = False
    for t in reversed(traces):
        try:
            doms = json.loads(t).get("domains", {})
        except ValueError:
            continue
        seen = True
        d = doms.get(EVENT_DOMAIN, {})
        if isinstance(d, dict) and "draws" in d:
            return int(d["draws"])
    return 0 if seen else None


arms = {}
for name, (pa, pb) in (("QUIET", (sys.argv[1], sys.argv[2])),
                       ("EVENT", (sys.argv[3], sys.argv[4]))):
    a, ta = load(pa)
    b, tb = load(pb)
    if a is None or b is None:
        which = "first" if a is None else "second"
        print("ERROR: the %s run of the %s arm printed no SIM_REPORT — refusing to call that "
              "determinism." % (which, name), file=sys.stderr)
        sys.exit(2)
    arms[name] = (a, b, ta, tb)

# POSITIVE CONTROL. A gate whose arm draws nothing cannot fail, so establish that the event arm drew.
qd = planet_draws(arms["QUIET"][2])
ed = planet_draws(arms["EVENT"][2])
if qd is None or ed is None:
    print("ERROR: no RNG_TRACE at all (needs a run of at least 180 frames). The event arm cannot be "
          "shown to have drawn anything.", file=sys.stderr)
    sys.exit(2)
if ed <= qd:
    print("ERROR: the event arm drew no more from the '%s' stream than the quiet arm, so no ambient "
          "event happened and this gate would pass on an empty world." % EVENT_DOMAIN, file=sys.stderr)
    sys.exit(2)
print("CONTROL  the event arm drew %d more from the '%s' stream than the quiet arm" % (ed - qd, EVENT_DOMAIN))

fail = False
for name in ("QUIET", "EVENT"):
    a, b, ta, tb = arms[name]

    horizon_same = True
    for k in HORIZON:
        x, y = a.get(k), b.get(k)
        if isinstance(x, (int, float)) and isinstance(y, (int, float)) and x != y:
            horizon_same = False
            print("%-5s HORIZON  %-22s %r vs %r" % (name, k, x, y))
    if not horizon_same:
        print("VERDICT: the %s arm's two runs did not simulate the same amount of time. Nothing below is "
              "comparable; fix the step loop first." % name)
        fail = True

    rng_same = ta == tb
    if not ta or not tb:
        print("%-5s RNG      no RNG_TRACE in the output — RNG not exonerated" % name)
    elif rng_same:
        print("%-5s RNG      identical draw counts in every domain across both runs" % name)
    else:
        print("%-5s RNG      the seeded streams DIVERGED — first differing trace line:" % name)
        for x, y in zip(ta, tb):
            if x != y:
                print("           A %s" % x)
                print("           B %s" % y)
                break
        fail = True

    fa, fb = flat(a), flat(b)
    shown, differing = 0, 0
    for k in sorted(set(fa) | set(fb)):
        if HOST.search(k) or k in HORIZON:
            continue
        x, y = fa.get(k), fb.get(k)
        if x == y:
            continue
        differing += 1
        if shown < MAX_SHOWN:
            print("%-5s READING  %-22s %r vs %r" % (name, k, x, y))
            shown += 1
        fail = True
    if differing == 0:
        print("%-5s READING  every reading the report publishes agrees, to the digit" % name)
    elif differing > shown:
        print("%-5s READING  and %d more" % (name, differing - shown))

if not fail:
    print("check_determinism: OK (same seed, same planet, to the digit, with and without an arrival)")
    sys.exit(0)
sys.exit(1)
PY
rc=$?
exit $rc
