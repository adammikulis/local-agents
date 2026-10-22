#!/usr/bin/env bash
# EVERY STAND-IN'S THREE STATES ARE REAL STATES. The life demo runs in the defaults and with each record
# `off`, arms dealt over PARTS processes that share one bake; each record is read in all three states at the
# seam. The world reads a stand-in through LAFakes.stands_in alone, so `real` is the run `off` already makes.
# EXIT 0 the states are the states * 1 one is not * 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3
require_tool rg

HOST="addons/local_agents/tests/gate_fakes_states.gd"
[ -f "$ROOT/$HOST" ] || { echo "check_fakes_states: no $HOST" >&2; exit 2; }
FRAMES="${LA_FAKE_STATE_FRAMES:-120}"
PARTS=2

READERS="$(rg -n -e 'state_real\(\)|state_off\(\)|LAAblate\.state_of\(|LAFakes\.states\(\)' "$ROOT/addons/local_agents" \
	--glob '*.gd' --glob '!**/tests/**' --glob '!**/LAFakes.gd' --glob '!**/EcologyService.gd' \
	--glob '!**/AblationSweep.gd' --glob '!**/SwitchPanel.gd' || true)"
if [ -n "$READERS" ]; then
	echo "$READERS" >&2
	echo "check_fakes_states: the world reads a stand-in's state without LAFakes.stands_in, so it can tell" >&2
	echo "                    real from off, and real is no longer the run off already makes." >&2
	exit 1
fi

OUT="$(mktemp -d "${TMPDIR:-/tmp}/la_fake_states.XXXXXX")"
cleanup() {
	local f
	while IFS= read -r f; do
		case "$f" in */la_field_cache/*.bin) rm -f -- "$f" ;; esac
	done < <(rg -IN -o -r '$1' -e '^FAKE_STATES_BAKE=(.*)$' "$OUT" --glob 'run*.log' 2>/dev/null | sort -u)
	rm -rf "$OUT"
}
trap cleanup EXIT INT TERM

export LA_SEAL_KEY="gate_fakes_states_$$_$(date +%s)"
for i in $(seq 0 $((PARTS - 1))); do
	LA_RUN_TIMEOUT="${LA_FAKE_STATE_TIMEOUT:-120}" "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
		-s "res://$HOST" --fixed-fps 60 -- --sandbox "--run-frames=$FRAMES" "--part=$i/$PARTS" > "$OUT/run$i.log" 2>&1
	echo "$?" > "$OUT/run$i.rc"
	rg -q '^LA_RUN_COMPLETE=' "$OUT/run$i.log" || break
done

python3 - "$OUT" "$FRAMES" "$PARTS" <<'PY'
import json, os, re, sys

out_dir, frames, parts = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
fails = []
logs = []


def unrun(why, part=None):
    lines, rc = logs[part] if part is not None and part < len(logs) else ([], 0)
    print("check_fakes_states: %s (exit %d)." % (why, rc), file=sys.stderr)
    print("\n".join(lines[-25:]), file=sys.stderr)
    sys.exit(2)


def marker(line, prefix):
    return json.loads(re.sub(r"(?<![\w.])-?(nan|inf)(?![\w.])", "null", line[len(prefix):]))


for i in range(parts):
    path = os.path.join(out_dir, "run%d.log" % i)
    if not os.path.isfile(path):
        unrun("part %d of %d never ran" % (i, parts))
    logs.append((open(path, errors="replace").read().splitlines(),
                 int(open(os.path.join(out_dir, "run%d.rc" % i)).read().strip() or 1)))

plan, seams, arms = [], None, {}
for part, (lines, _) in enumerate(logs):
    if not any(ln.startswith("LA_RUN_COMPLETE=") for ln in lines):
        unrun("part %d never completed" % part, part)
    cur = None
    for ln in lines:
        if ln.startswith("FAKE_STATES_PLAN="):
            plan += marker(ln, "FAKE_STATES_PLAN=")
        elif ln.startswith("FAKE_STATES_ARM="):
            cur = marker(ln, "FAKE_STATES_ARM=")["arm"]
            arms[cur] = {"lines": [], "code": None}
            continue
        elif ln.startswith("FAKE_STATES_SEAMS="):
            seams, cur = marker(ln, "FAKE_STATES_SEAMS="), None
        elif cur is not None and ln.startswith("FAKE_STATES_END="):
            arms[cur]["code"] = marker(ln, "FAKE_STATES_END=")["code"]
        if cur is not None:
            arms[cur]["lines"].append(ln)

if "defaults" not in plan or len(plan) < 2:
    unrun("LAFakes declares no record, so no arm was planned", 0)
if seams is None:
    unrun("the run read no state at the seam", parts - 1)
names = [a[:-len(".off")] for a in plan if a != "defaults"]


def read(arm):
    got = arms.get(arm)
    if got is None or got["code"] is None:
        unrun("the %s arm never ended" % arm)
    reports = [l for l in got["lines"] if l.startswith("SIM_REPORT=")]
    if not reports:
        unrun("the %s arm published no SIM_REPORT, so nothing was measured" % arm)
    try:
        snap = marker(reports[-1], "SIM_REPORT=")
    except ValueError as e:
        unrun("the %s arm's SIM_REPORT is not readable: %s" % (arm, e))
    text = "\n".join(got["lines"])
    verdicts = re.findall(r"^(CONSERVATION_VIOLATION|CONSERVATION_UNMEASURED|PRESSURE_BROKEN)=", text, re.M)
    return {"snap": snap, "text": text, "code": got["code"], "verdicts": verdicts,
            "errors": [l for l in got["lines"] if "SCRIPT ERROR" in l]}


base = read("defaults")
for arm in plan:
    steps = int(read(arm)["snap"].get("sim_steps", -1))
    if steps != frames:
        fails.append("the %s arm ran %d steps, not the %d it was given, so it was not one fresh world"
                     % (arm, steps, frames))
base_states = base["snap"].get("fake_states")
if not isinstance(base_states, dict) or not base_states:
    unrun("the run publishes no fake_states, so no state can be read back")
for n in names:
    if base_states.get(n) != "fake":
        fails.append("in the defaults '%s' reads %r, not the stand-in this rung has no field for"
                     % (n, base_states.get(n)))

rows = []
for n in names:
    arm = read("%s.off" % n)
    got = (arm["snap"].get("fake_states") or {}).get(n)
    if got != "off":
        fails.append("%s:off left '%s' reading %r" % (n, n, got))
    if n in (arm["snap"].get("fakes") or {}):
        fails.append("'%s' switched to off still keeps a stand-in's book" % n)
    if arm["errors"]:
        fails.append("'%s' switched to off threw %d script error(s), first: %s"
                     % (n, len(arm["errors"]), arm["errors"][0].strip()))
    if not arm["snap"].get("world_sealed") and "WORLD_SEALED=" not in arm["text"]:
        fails.append("'%s' switched to off never sealed its world" % n)
    if arm["code"] != 0 or arm["verdicts"]:
        fails.append("'%s' switched to off ended %d%s" % (n, arm["code"],
                     " with " + ", ".join(sorted(set(arm["verdicts"]))) if arm["verdicts"] else ""))
    for state, wrong in sorted((seams.get(n) or {}).items()):
        for w in wrong:
            fails.append("'%s' switched to %s at the seam: %s" % (n, state, w))
    if sorted((seams.get(n) or {})) != ["fake", "off", "real"]:
        fails.append("'%s' was not read in all three states at the seam" % n)
    book = (base["snap"].get("fakes") or {}).get(n) or {}
    rows.append({"fake": n, "drew": int(book.get("draws", 0)) > 0})

# THE POSITIVE CONTROL. A run in which no stand-in was ever drawn on measured nothing: the books the
# arms that switch one off must not carry were never written in the first place.
if not [r for r in rows if r["drew"]]:
    unrun("no stand-in handed anything out in the defaults, so the arms that must hand out nothing prove nothing")

print("FAKE_STATES=" + json.dumps(rows))
if fails:
    for f in fails:
        print("  " + f, file=sys.stderr)
    print("check_fakes_states: FAIL (%d)" % len(fails))
    sys.exit(1)
print("check_fakes_states: OK")
PY
