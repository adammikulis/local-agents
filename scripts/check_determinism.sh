#!/usr/bin/env bash
# THE SAME SEED MUST GIVE THE SAME PLANET. Two runs, one seed, one length -> diff every reading.
# Not in `lint` (four windowed runs, minutes). TWO ARMS: a world where nothing happens agrees with itself
# however broken it is, so the event arm makes something happen -- `--stamp-test` deposits rock through the
# injection queue at every rung that has a field. CONTROL: both event runs carry the deposit marker,
# neither quiet run does, and the arms read differently somewhere. What the verdict separates:
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
run_one "$EA" --stamp-test
run_one "$EB" --stamp-test

python3 - "$QA" "$QB" "$EA" "$EB" <<'PY'
import json, re, sys

# The horizon decides whether anything else is comparable, so it is checked first and separately.
HORIZON = ("field_step", "field_sim_s")
# Readings OF THE HOST, not of the world: wall-clock costs, the frame rate they imply, driver memory.
HOST = re.compile(r"(^|\.)(fps|video_mem_MB)(\.|$)|_ms(\.|$)")
# The line VoxelInputController prints when --stamp-test puts rock into a void cell.
EVENT_MARKER = "STAMP_TEST_DEPOSIT="
MAX_SHOWN = 12


def load(path):
    report, traces, marks = None, [], 0
    for line in open(path, errors="replace"):
        if line.startswith("SIM_REPORT="):
            report = line[11:]
        elif line.startswith("RNG_TRACE="):
            traces.append(line[10:].strip())
        elif line.startswith(EVENT_MARKER):
            marks += 1
    return (json.loads(report) if report else None), traces, marks


def flat(d, prefix=""):
    out = {}
    for k, v in d.items():
        key = prefix + str(k)
        if isinstance(v, dict):
            out.update(flat(v, key + "."))
        else:
            out[key] = v
    return out


def flat_readings(d):
    out = {}
    for k, v in flat(d).items():
        if HOST.search(k) or k in HORIZON:
            continue
        out[k] = v
    return out


arms = {}
for name, (pa, pb) in (("QUIET", (sys.argv[1], sys.argv[2])),
                       ("EVENT", (sys.argv[3], sys.argv[4]))):
    a, ta, ma = load(pa)
    b, tb, mb = load(pb)
    if a is None or b is None:
        which = "first" if a is None else "second"
        print("ERROR: the %s run of the %s arm printed no SIM_REPORT — refusing to call that "
              "determinism." % (which, name), file=sys.stderr)
        sys.exit(2)
    arms[name] = (a, b, ta, tb, ma + mb)

# POSITIVE CONTROL. A gate whose event arm did nothing cannot fail: the two runs of an empty world agree
# however broken the substrate is. So the event arm must have deposited, the quiet arm must not have, and
# the two arms must read differently somewhere.
if arms["QUIET"][4] != 0:
    print("ERROR: the quiet arm carries %d '%s' line(s). It is supposed to be the arm where nothing "
          "happens." % (arms["QUIET"][4], EVENT_MARKER), file=sys.stderr)
    sys.exit(2)
if arms["EVENT"][4] < 2:
    print("ERROR: the event arm carries %d '%s' line(s) across its two runs, not 2, so the injection never "
          "happened and this gate would pass on an empty world." % (arms["EVENT"][4], EVENT_MARKER),
          file=sys.stderr)
    sys.exit(2)
qr, er = flat_readings(arms["QUIET"][0]), flat_readings(arms["EVENT"][0])
moved = sorted(k for k in set(qr) | set(er) if qr.get(k) != er.get(k))
if not moved:
    print("ERROR: the event arm deposited and not one reading the report publishes moved, so the injection "
          "did not reach the books and the comparison below is between two identical empty worlds.",
          file=sys.stderr)
    sys.exit(2)
print("CONTROL  the event arm deposited and %d reading(s) differ from the quiet arm (%s)"
      % (len(moved), ", ".join(moved[:4])))

fail = False
for name in ("QUIET", "EVENT"):
    a, b, ta, tb, _marks = arms[name]

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
    print("check_determinism: OK (same seed, same planet, to the digit, with and without a deposit)")
    sys.exit(0)
sys.exit(1)
PY
rc=$?
exit $rc
