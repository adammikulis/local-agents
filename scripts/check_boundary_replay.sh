#!/usr/bin/env bash
# A REPLAY FACE HOLDS THE EXTERIOR RECORDED FOR THE STEP IT IS AT. A global run records the slice box's
# exterior on LASimLoop's step; a REPLAY slice over that capture books what its faces hold from each step.
# The two books must agree step for step, bit-identical in the device's float32, from the loop's first
# step, so a clock offset on either side, or a sample fed early or late, is red.
# EXIT 0 aligned · 1 a face held another step's exterior · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3
require_tool rg
. "$ROOT/scripts/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?

WORK="$(mktemp -d "${TMPDIR:-/tmp}/la_bnd_replay.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

# THE CAPTURE: the lint's shared body arm, or a short body run of this gate's own.
if la_cap_dir >/dev/null; then
	CAP="$(la_cap_state)" || exit 2
	RUNG="$(la_cap_rung)" || { echo "check_boundary_replay: the shared capture names no rung." >&2; exit 2; }
else
	CAP="$WORK/capture.json"
	RUNG="${LA_REPLAY_RUNG:-$(rg -N -o '^[0-9]+$' "$ROOT/docs/PLAYABLE_RUNG" | head -1)}"
	"$ROOT/scripts/sim_run.sh" --path "$ROOT" --body --rung "$RUNG" --frames 20 --slice-capture "$CAP" \
		--report h2o_total > "$WORK/capture.out" 2>&1
fi
# The replay crosses one change of sample and stops half a cadence short of the next.
FRAMES="$(python3 - "$CAP" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    s = d["samples"]
    print(int(s[1]["step"]) + int(d["cadence"]) // 2)
except Exception as exc:
    print("check_boundary_replay: the capture holds no two samples (%s)." % exc, file=sys.stderr)
    raise SystemExit(2)
PY
)" || { tail -8 "$WORK/capture.out" 2>/dev/null >&2; exit 2; }

BOOK="$WORK/book.json"
LA_SLICE_REPLAY=1 LA_SLICE_REPLAY_BOOK="$BOOK" "$ROOT/scripts/sim_run.sh" --path "$ROOT" --rung "$RUNG" \
	--slice-state "$CAP" --frames "$FRAMES" --keep --report h2o_total > "$WORK/replay.out" 2>&1
rc=$?
LOG="$(sed -n 's/^sim_run: log kept at //p' "$WORK/replay.out" | head -1)"
[ -n "$LOG" ] && [ -f "$LOG" ] && mv -f "$LOG" "$WORK/replay.log"
# A replay that refused a step outside the recording, or a series off its own cadence, found the two
# clocks apart: that is the verdict.
REFUSED='LAFieldBoundaryCapture3D: (the capture (begins|ends) at step|.*a gapped series cannot drive)'
if grep -qE "$REFUSED" "$WORK/replay.log" 2>/dev/null; then
	grep -m1 -E "$REFUSED" "$WORK/replay.log" >&2
	echo "FAIL: the replay asked for an exterior the capture did not record at that step." >&2
	exit 1
fi
if ! grep -q '^SLICE_BOUNDARY=.*replay' "$WORK/replay.log" 2>/dev/null; then
	echo "check_boundary_replay: the slice stood up no REPLAY face (sim_run exit $rc)." >&2
	tail -12 "$WORK/replay.out" >&2
	exit 2
fi
case "$rc" in
	0|122|123|126) ;;
	*) echo "check_boundary_replay: the replay run failed (sim_run exit $rc)." >&2
	   tail -12 "$WORK/replay.out" >&2
	   exit 2 ;;
esac

python3 - "$CAP" "$BOOK" "$FRAMES" <<'PY'
import json, struct, sys

cap_path, book_path, frames = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    cap = json.load(open(cap_path))
    book = json.load(open(book_path))
except Exception as exc:
    print("check_boundary_replay: a book is unreadable (%s)." % exc, file=sys.stderr)
    raise SystemExit(2)


def f32(x):
    return struct.unpack("<f", struct.pack("<f", float(x)))[0]


def numbers(st):
    out = {"temp_c": st["temp_c"], "pressure_pa": st["pressure_pa"]}
    for k in ("velocity", "gravity"):
        for i, v in enumerate(st[k]):
            out["%s[%d]" % (k, i)] = v
    for name, v in st["amounts"].items():
        out["amounts.%s" % name] = v
    return out


recorded = {int(s["step"]): s["faces"] for s in cap["samples"]}
want = sorted(t for t in recorded if t <= frames)
held = book.get("samples", [])
got = [int(e["step"]) for e in held]
up = int(cap.get("up_slot", -1))
fails = []
if up < 0:
    print("check_boundary_replay: the capture names no outward face.", file=sys.stderr)
    raise SystemExit(2)
if len(want) < 2:
    print("check_boundary_replay: the capture reaches %d sample(s) in %d steps; no change of sample is "
          "replayed." % (len(want), frames), file=sys.stderr)
    raise SystemExit(2)
if got != want:
    fails.append("the faces took samples on at steps %s; the capture recorded %s" % (got, want))
compared = 0
for e in held:
    step = int(e["step"])
    if int(e.get("recorded_step", -1)) != step:
        fails.append("step %d holds the sample recorded at step %s" % (step, e.get("recorded_step")))
    if step not in recorded:
        continue
    if sorted(e["faces"]) != sorted([str(up), str(up ^ 1)]):
        fails.append("step %d books faces %s, not the vertical pair %d/%d" % (step, sorted(e["faces"]), up, up ^ 1))
    for face, st in e["faces"].items():
        mine, theirs = numbers(st), numbers(recorded[step][face])
        if sorted(mine) != sorted(theirs):
            fails.append("step %d face %s books %s against %s" % (step, face, sorted(mine), sorted(theirs)))
            continue
        for k in sorted(mine):
            compared += 1
            if f32(mine[k]) != f32(theirs[k]):
                fails.append("step %d face %s %s holds %r where the capture recorded %r"
                             % (step, face, k, mine[k], theirs[k]))
                break
print('BOUNDARY_REPLAY={"steps":%s,"numbers":%d,"failures":%d}' % (json.dumps(got), compared, len(fails)))
for f in fails:
    print("FAIL: " + f, file=sys.stderr)
if compared == 0 and not fails:
    print("check_boundary_replay: no number was compared.", file=sys.stderr)
    raise SystemExit(2)
raise SystemExit(1 if fails else 0)
PY
v=$?
[ "$v" -eq 0 ] && echo "check_boundary_replay: OK"
exit "$v"
