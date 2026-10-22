#!/usr/bin/env bash
# THE NATIVE SIM RUNS THE FIELD'S PASSES AND GETS THE SAME ANSWER AS GODOT. The oracle is a box of cells
# seeded from the substance table and stepped by StateDerivePass and ReducePass themselves, which write
# an LAFieldSnapshot before and after and record the plan they produced. lasim replays it.
# EXIT 0 the two agree * 1 they do not, or arm C went unnoticed * 2 could not run.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib_require.sh"
. "$SCRIPT_DIR/lib_godot_lock.sh"
. "$SCRIPT_DIR/lib_lasim.sh"
. "$SCRIPT_DIR/lib_lasim_oracle.sh"
. "$SCRIPT_DIR/lib_capture.sh"
require_tool python3
require_tool cmake

GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "check_lasim_parity: no godot on PATH." >&2; exit 2; }
[ -f "$ROOT/scripts/run_sim_offscreen.sh" ] || {
	echo "check_lasim_parity: run_sim_offscreen.sh missing." >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/la_lasim_parity.XXXXXX")" || {
	echo "check_lasim_parity: no writable temp directory." >&2; exit 2; }
lock_rc=1
cleanup() {
	la_lasim_oracle_clean
	rm -rf "$WORK"
	[ "$lock_rc" -eq 0 ] && la_gpu_unlock
}
trap cleanup EXIT INT TERM

la_lasim_oracle_write
la_lasim_build || exit 2

STEPS="${LA_PARITY_STEPS:-2}"
GODOT_LOG="$WORK/godot.log"
la_lasim_oracle_run "$WORK" "$STEPS" || exit 2

# ONE GPU AT A TIME, and only over the runs that make a device here: a Godot launch takes the extension
# lock before the GPU lock, so holding this across one deadlocks against a lane holding the other.
la_gpu_lock
lock_rc=$?
[ "$lock_rc" -eq 1 ] && { echo "check_lasim_parity: the GPU lock did not come free." >&2; exit 2; }

# ARM A: the same state Godot reduced, reduced again by lasim. Both fold the same float32 partials in
# float64, so every row must be the same double.
if ! la_lasim --load "$WORK/godot_mirrors.lafs" --plan "$WORK/plan_reduce.lapl" --passes reduce \
		--steps 1 --report > "$WORK/fold.log" 2>&1; then
	echo "check_lasim_parity: lasim did not complete the fold arm." >&2
	tail -25 "$WORK/fold.log" >&2
	exit 2
fi
# ARM B: the same seed state, derived and reduced by lasim, with its derived channels written back.
# Not exact: Godot's Metal driver compiles with fast math, la::Device with MTLMathModeSafe.
if ! la_lasim --load "$WORK/field.lafs" --plan "$WORK/plan.lapl" --passes derive,reduce \
		--steps "$STEPS" --mirrors "$WORK/lasim_mirrors.lafs" > "$WORK/derive.log" 2>&1; then
	echo "check_lasim_parity: lasim did not complete the derive arm." >&2
	tail -25 "$WORK/derive.log" >&2
	exit 2
fi
grep -E '^LASIM_RUN=' "$WORK/derive.log" || true

# ARMS C AND E: the plan carries the driver's work in two tables, and a comparison blind to either is
# blind to half of what the driver decides. C flips one bit of one recorded push-constant block, where a
# row's masks and partial base live. E turns one publishing row's fold to SKIP, in the row table where
# the key and the fold shape live.
python3 - "$WORK/plan_reduce.lapl" "$WORK/plan_mutated.lapl" "$WORK/plan_mutated_fold.lapl" <<'PY'
import struct, sys
raw = bytearray(open(sys.argv[1], 'rb').read())
at = 20
def u32():
	global at
	v = struct.unpack_from('<I', raw, at)[0]
	at += 4
	return v
def skip(n):
	global at
	at += n
for _ in range(struct.unpack_from('<I', raw, 16)[0]):
	skip(u32()); elems = u32(); u32(); skip(elems * 4)
for _ in range(u32()):
	skip(u32())
	for _ in range(u32()):
		u32(); u32()
found = None
for _ in range(u32()):
	for _ in range(u32()):
		skip(u32()); u32(); u32()
		n = u32()
		# `base`, the row's first partial slot: the fourth word of reduce.glsl's Params.
		if found is None and n >= 16:
			found = at + 12
		skip(n)
if found is None:
	sys.exit("no push-constant block to mutate")
# The row table: { u32 len, key, u32 fold }. FOLD_SKIP is 3, so a publishing row is any other fold.
fold_at = None
for _ in range(u32()):
	skip(u32())
	if fold_at is None and struct.unpack_from('<I', raw, at)[0] != 3:
		fold_at = at
	skip(4)
if fold_at is None:
	sys.exit("every row of the plan already folds to SKIP, so no row publishes")
if at != len(raw):
	sys.exit("the plan carries %d bytes past its own end" % (len(raw) - at))
pc = bytearray(raw)
pc[found] ^= 0x01
open(sys.argv[2], 'wb').write(bytes(pc))
fold = bytearray(raw)
struct.pack_into('<I', fold, fold_at, 3)
open(sys.argv[3], 'wb').write(bytes(fold))
PY
for mutant in plan_mutated plan_mutated_fold; do
	[ -s "$WORK/$mutant.lapl" ] || {
		echo "check_lasim_parity: $mutant carries no plan, so this gate has no positive control." >&2
		exit 2
	}
done
if ! la_lasim --load "$WORK/godot_mirrors.lafs" --plan "$WORK/plan_mutated.lapl" --passes reduce \
		--steps 1 --report > "$WORK/mutant.log" 2>&1; then
	echo "check_lasim_parity: the mutated plan did not run; the control proves nothing." >&2
	tail -20 "$WORK/mutant.log" >&2
	exit 2
fi
if ! la_lasim --load "$WORK/godot_mirrors.lafs" --plan "$WORK/plan_mutated_fold.lapl" --passes reduce \
		--steps 1 --report > "$WORK/mutant_fold.log" 2>&1; then
	echo "check_lasim_parity: the fold-mutated plan did not run; the control proves nothing." >&2
	tail -20 "$WORK/mutant_fold.log" >&2
	exit 2
fi

python3 - "$WORK" <<'PY'
import json, math, os, struct, sys

work = sys.argv[1]

def rows(name, marker):
	for line in open(os.path.join(work, name)):
		if line.startswith(marker):
			return json.loads(line[len(marker):])
	return None

godot = {k: struct.unpack("<d", bytes.fromhex(v))[0]
	for k, v in (rows("godot.log", "GODOT_ROWS=") or {}).items()}
native = rows("fold.log", "SIM_REPORT=")
mutant = rows("mutant.log", "SIM_REPORT=")
mutant_fold = rows("mutant_fold.log", "SIM_REPORT=")
if native is None or mutant is None or mutant_fold is None:
	print("check_lasim_parity: an arm published no rows.", file=sys.stderr)
	sys.exit(2)
if not godot:
	print("check_lasim_parity: the oracle folded no rows, so nothing was compared.", file=sys.stderr)
	sys.exit(2)

fail = False

# ARM A. Both sides fold the SAME float32 partials in float64, in the same row order, so a row that is
# not the identical double is a row one of them folded differently.
def differ(a, b):
	out = []
	for k in sorted(set(a) | set(b)):
		if k not in a or k not in b:
			out.append("row %s: only %s has it" % (k, "the oracle" if k in a else "the native run"))
			continue
		x, y = (float("nan") if v is None else float(v) for v in (a[k], b[k]))
		if x == y or (math.isnan(x) and math.isnan(y)):
			continue
		out.append("row %s: %.17g against %.17g" % (k, x, y))
	return out

bad = differ(godot, native)
if bad:
	fail = True
	print("FAIL  the fold arm: %d row(s) are not the same double:" % len(bad), file=sys.stderr)
	for b in bad[:12]:
		print("      " + b, file=sys.stderr)

# ARM C.
if not differ(godot, mutant):
	print("FAIL  a flipped bit in a recorded push-constant block moved no row, so this comparison "
		"cannot see a plan defect.", file=sys.stderr)
	fail = True

# ARM E.
if not differ(godot, mutant_fold):
	print("FAIL  a publishing row turned to SKIP in the plan's row table still published, so this "
		"comparison cannot see a fold defect.", file=sys.stderr)
	fail = True

# ARM B. float32 unit roundoff is 2^-24; Godot's Metal driver compiles with fast math and la::Device with
# MTLMathModeSafe, so one side may reassociate or contract an expression the other evaluates in order.
# The derive's per-cell expression tree is at most ~32 roundings deep, so 2^-19 bounds their difference.
BOUND = 2.0 ** -19
# state_derive.glsl's (T, p) solve is pinned by its own stopping criterion, not by roundoff: it accepts
# only once |dp| and |dT| between outer iterations are under LA_STATE_TOL, so both modes land inside that
# and no channel of the solved state is left out of this comparison.
SOLVED_K = 1.0e-3
SOLVED = {"temp": SOLVED_K, "temp_lith": SOLVED_K}
# A pressure read off a difference of two nearly-equal volumes, and the temperature the same solve
# states, do not land in the same place under both math modes: check_derive_safe_math.sh owns them.
SAFE_MATH = ("pressure", "p_fluid", "k_cond", "temp", "temp_lith")

def mirrors(path):
	raw = open(path, "rb").read()
	at = 0
	def u32():
		nonlocal at
		v = struct.unpack_from("<I", raw, at)[0]
		at += 4
		return v
	def s():
		nonlocal at
		n = u32()
		v = raw[at:at + n].decode("utf-8")
		at += n
		return v
	if u32() != 0x5346414C:
		sys.exit(path + " is not a field snapshot")
	u32()
	cells = u32()
	count = u32()
	s()
	names = [s() for _ in range(count)]
	return cells, names, raw[at:]

g_cells, g_names, g_body = mirrors(os.path.join(work, "godot_mirrors.lafs"))
n_cells, n_names, n_body = mirrors(os.path.join(work, "lasim_mirrors.lafs"))
if g_cells != n_cells or g_names != n_names:
	print("FAIL  the derive arm wrote back %d cells over %d channels against %d over %d."
		% (n_cells, len(n_names), g_cells, len(g_names)), file=sys.stderr)
	fail = True
else:
	moved = []
	compared = 0
	for i, name in enumerate(g_names):
		if name in SAFE_MATH:
			continue
		off = i * g_cells * 4
		a = struct.unpack_from("<%df" % g_cells, g_body, off)
		b = struct.unpack_from("<%df" % g_cells, n_body, off)
		absolute = SOLVED.get(name)
		bound = absolute if absolute is not None else BOUND
		compared += 1
		out = 0
		worst = 0.0
		for x, y in zip(a, b):
			if x == y or (math.isnan(x) and math.isnan(y)):
				continue
			if math.isinf(x) or math.isinf(y):
				out += 1
				continue
			d = abs(x - y) if absolute is not None else abs(x - y) / max(abs(x), abs(y), 1.0)
			worst = max(worst, d)
			if d > bound:
				out += 1
		if out:
			moved.append((name, out, worst, "K" if absolute is not None else "relative"))
	if compared == 0:
		print("check_lasim_parity: no derived channel was compared.", file=sys.stderr)
		sys.exit(2)
	if moved:
		fail = True
		print("FAIL  the derive arm: %d of %d channel(s) outside their bound:" % (len(moved), compared),
			file=sys.stderr)
		for name, out, worst, unit in moved[:12]:
			print("      %s: %d of %d cells, worst %s %.3g" % (name, out, g_cells, unit, worst),
				file=sys.stderr)
	print("check_lasim_parity: %d derived channel(s) compared; %s left to "
		"check_derive_safe_math.sh." % (compared, ", ".join(SAFE_MATH)))

sys.exit(1 if fail else 0)
PY
RC=$?
[ "$RC" -eq 0 ] || exit "$RC"

[ "$lock_rc" -eq 0 ] && la_gpu_unlock
lock_rc=1

# ARM D. The box above is not the planet, so the reading the comparison rests on is taken off a real
# run: off the shared capture the lint records, or its own when there is none.
la_report derive_unconverged_cells,nonfinite_cells --rung 1 > "$WORK/seeded.txt" 2>&1
seeded_rc=$?
cat "$WORK/seeded.txt"
if [ "$seeded_rc" -ne 0 ]; then
	echo "check_lasim_parity: the seeded world published no derive reading, so the comparison above" >&2
	echo "                    rests on a box and nothing else." >&2
	exit 2
fi
seeded_fail=0
for key in derive_unconverged_cells nonfinite_cells; do
	value="$(sed -n "s/.*${key}[^0-9eE.+-]*\(-\{0,1\}[0-9][0-9.eE+-]*\).*/\\1/p" "$WORK/seeded.txt" \
		| head -1)"
	if [ -z "$value" ]; then
		echo "check_lasim_parity: the seeded world published no ${key}." >&2
		exit 2
	fi
	if [ "$(printf '%s' "$value" | awk '{print ($1 == 0) ? "zero" : "moved"}')" != "zero" ]; then
		echo "FAIL  the seeded world reads ${key} = ${value}, so its derive did not settle and the two" >&2
		echo "      paths above were compared on iterates." >&2
		seeded_fail=1
	fi
done
[ "$seeded_fail" -eq 0 ] || exit 1
echo "check_lasim_parity: OK"
