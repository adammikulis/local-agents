#!/usr/bin/env bash
# EVERY STAND-IN'S THREE STATES ARE REAL STATES. Per LAFakes record the life demo runs in `real` and in
# `off` against one run in the defaults: neither hands the world anything of its own, a run below the
# record's rung leaves the same life standing in both (the field's answer to an absent process is the
# absence), and the defaults differ from `off` or the record is standing in for nothing.
# EXIT 0 the states are the states * 1 one is not * 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_godot.sh"
require_tool python3

SCENE="addons/local_agents/examples/LifeDemo.tscn"
FAKES_GD="addons/local_agents/sim/LAFakes.gd"
for f in "$SCENE" "$FAKES_GD"; do
	[ -f "$ROOT/$f" ] || { echo "check_fakes_states: no $f" >&2; exit 2; }
done
FRAMES="${LA_FAKE_STATE_FRAMES:-120}"

NAMES="$(python3 - "$ROOT/$FAKES_GD" <<'PY'
import re, sys
src = open(sys.argv[1], errors="replace").read()
body = src.split("const RECORDS", 1)[-1].split("\n]", 1)[0]
for b in re.findall(r"\{(.*?)\},", body, re.S):
    m = re.search(r'"name":\s*"([a-z0-9_]+)"', b)
    if m:
        print(m.group(1))
PY
)"
[ -n "$NAMES" ] || { echo "check_fakes_states: LAFakes declares no record." >&2; exit 2; }

OUT="$(mktemp -d "${TMPDIR:-/tmp}/la_fake_states.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT INT TERM

run_arm() {  # $1 log basename, $2... extra user args
	local name="$1"; shift
	LA_RUN_TIMEOUT="${LA_FAKE_STATE_TIMEOUT:-110}" "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
		"$SCENE" --fixed-fps 60 -- --sandbox "--run-frames=$FRAMES" "$@" > "$OUT/$name.log" 2>&1
	echo "$?" > "$OUT/$name.rc"
}

run_arm defaults
for n in $NAMES; do
	run_arm "$n.real" "--ablate=$n:real"
	run_arm "$n.off" "--ablate=$n:off"
done

python3 - "$OUT" "$ROOT/$FAKES_GD" "$NAMES" <<'PY'
import json, os, re, sys

out_dir, fakes_gd, names = sys.argv[1], sys.argv[2], sys.argv[3].split()
src = open(fakes_gd, errors="replace").read()
body = src.split("const RECORDS", 1)[-1].split("\n]", 1)[0]
rungs = {}
for b in re.findall(r"\{(.*?)\},", body, re.S):
    m = re.search(r'"name":\s*"([a-z0-9_]+)"', b)
    r = re.search(r'"rung":\s*LAProcessSet\.([A-Z_]+)', b)
    if m:
        rungs[m.group(1)] = r.group(1) if r else None

fails = []


def read(arm):
    log = os.path.join(out_dir, arm + ".log")
    if not os.path.isfile(log):
        print("check_fakes_states: the %s arm never ran." % arm, file=sys.stderr)
        sys.exit(2)
    text = open(log, errors="replace").read()
    rc = int(open(os.path.join(out_dir, arm + ".rc")).read().strip() or 1)
    reports = [l for l in text.splitlines() if l.startswith("SIM_REPORT=")]
    if not reports:
        print("check_fakes_states: the %s arm published no SIM_REPORT (exit %d), so nothing was "
              "measured." % (arm, rc), file=sys.stderr)
        print("\n".join(text.splitlines()[-25:]), file=sys.stderr)
        sys.exit(2)
    line = re.sub(r"(?<![\w.])-?(nan|inf)(?![\w.])", "null", reports[-1][len("SIM_REPORT="):])
    try:
        snap = json.loads(line)
    except ValueError as e:
        print("check_fakes_states: the %s arm's SIM_REPORT is not readable: %s" % (arm, e),
              file=sys.stderr)
        sys.exit(2)
    pops = [l[len("POP_TRACE="):] for l in text.splitlines() if l.startswith("POP_TRACE=")]
    counts = {}
    if pops:
        clean = re.sub(r"(?<![\w.])-?(nan|inf)(?![\w.])", "null", pops[-1])
        counts = (json.loads(clean).get("counts") or {})
    errs = [l for l in text.splitlines() if "SCRIPT ERROR" in l]
    return {"snap": snap, "counts": counts, "rc": rc, "errors": errs, "text": text}


def census(arm):
    # What the world ended up holding: every living kind, and the ledgers a stand-in feeds.
    snap = arm["snap"]
    out = {("count/" + k): int(v) for k, v in arm["counts"].items()}
    for key in ("veg_food_drawn", "veg_food_held", "veg_seed_cost", "biota_graze_taken",
                "biota_water_in", "biota_detritus_out", "biota_co2_out"):
        if key in snap:
            out[key] = snap[key]
    events = snap.get("events", {})
    for key in sorted(events):
        if key.startswith("death"):
            out["event/" + key] = int(events[key])
    return out


def kinds_alive(arm):
    # Which kinds are still standing. A count is a run's own arithmetic; which kinds SURVIVED is the
    # claim, and it does not move with a death landing one frame either side.
    return sorted(k for k, v in arm["counts"].items() if int(v) > 0)


base = read("defaults")
base_states = base["snap"].get("fake_states")
if not isinstance(base_states, dict) or not base_states:
    print("check_fakes_states: the run publishes no fake_states, so no state can be read back.",
          file=sys.stderr)
    sys.exit(2)
for n in names:
    if base_states.get(n) != "fake":
        fails.append("in the defaults '%s' reads %r, not the stand-in this rung has no field for"
                     % (n, base_states.get(n)))

rows = []
for n in names:
    arms = {state: read("%s.%s" % (n, state)) for state in ("real", "off")}
    for state, arm in arms.items():
        got = (arm["snap"].get("fake_states") or {}).get(n)
        if got != state:
            fails.append("--ablate=%s:%s left '%s' reading %r" % (n, state, n, got))
        # THE STAND-IN'S OWN SUPPLY IS GONE. Its book is written only while it is standing in.
        if n in (arm["snap"].get("fakes") or {}):
            fails.append("'%s' switched to %s still keeps a stand-in's book" % (n, state))
        if arm["errors"]:
            fails.append("'%s' switched to %s threw %d script error(s), first: %s"
                         % (n, state, len(arm["errors"]), arm["errors"][0].strip()))
        if not arm["snap"].get("world_sealed") and "WORLD_SEALED=" not in arm["text"]:
            fails.append("'%s' switched to %s never sealed its world" % (n, state))
        if arm["rc"] != 0:
            fails.append("'%s' switched to %s exited %d" % (n, state, arm["rc"]))

    # A RUNG THE WORLD DOES NOT CONTAIN ANSWERS NOTHING, so `real` leaves the same life standing as
    # `off`: the field's own query is what both of them read.
    real_k, off_k = kinds_alive(arms["real"]), kinds_alive(arms["off"])
    same = real_k == off_k
    if not same:
        fails.append("'%s' leaves %s alive in real and %s in off, but this run holds no %s process for "
                     "real to read" % (n, real_k or "nothing", off_k or "nothing",
                                       rungs.get(n) or "0.5"))

    # THE POSITIVE CONTROL. Either the stand-in handed matter out, or switching it off changed the
    # world; a record that does neither is standing in for nothing.
    book = (base["snap"].get("fakes") or {}).get(n) or {}
    drew = int(book.get("draws", 0))
    base_c, off_c = census(base), census(arms["off"])
    moved = sorted(k for k in set(base_c) | set(off_c) if base_c.get(k) != off_c.get(k))
    if drew <= 0 and not moved:
        fails.append("'%s' handed nothing out and switching it off changed nothing: it is standing in "
                     "for nothing" % n)
    rows.append({"fake": n, "draws": drew, "changed": len(moved), "real_is_off": same})

print("FAKE_STATES=" + json.dumps(rows))
if fails:
    for f in fails:
        print("  " + f, file=sys.stderr)
    print("check_fakes_states: FAIL (%d)" % len(fails))
    sys.exit(1)
print("check_fakes_states: OK")
PY
