#!/usr/bin/env bash
# THE CHANNELS OF THE SOLVED STATE THAT DO NOT YET SURVIVE THE ARITHMETIC. Godot's driver compiles the
# kernels with fast math and lasim's device at MTLMathModeSafe; a quantity read off a difference of two
# nearly-equal volumes does not land in the same place under both. Counted as a ratchet: it may fall.
# check_derive_fixed_point.sh and check_lasim_parity.sh own every other channel.
# EXIT 0 at or under the ceiling * 1 above it * 2 could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts"
. "$SCRIPT_DIR/lib_require.sh"
. "$SCRIPT_DIR/lib_godot_lock.sh"
. "$SCRIPT_DIR/lib_lasim.sh"
. "$SCRIPT_DIR/lib_lasim_oracle.sh"
. "$SCRIPT_DIR/lib_ceiling.sh" 2>/dev/null || true
require_tool python3
require_tool cmake
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "check_derive_safe_math: no godot on PATH." >&2; exit 2; }

CEIL_FILE="$REPO_ROOT/docs/DERIVE_SAFE_MATH_CEILING"
[ -f "$CEIL_FILE" ] || { echo "check_derive_safe_math: no docs/DERIVE_SAFE_MATH_CEILING." >&2; exit 2; }
CEIL="$(grep -E '^[0-9]+$' "$CEIL_FILE" | head -1)"
case "$CEIL" in "" | *[!0-9]*) echo "check_derive_safe_math: the ceiling carries no number." >&2; exit 2 ;; esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/la_derive_safe.XXXXXX")" || {
	echo "check_derive_safe_math: no writable temp directory." >&2; exit 2; }
lock_rc=1
cleanup() {
	la_lasim_oracle_clean
	rm -rf "$WORK"
	[ "$lock_rc" -eq 0 ] && la_gpu_unlock
}
trap cleanup EXIT INT TERM

la_lasim_oracle_write
la_lasim_build || exit 2
# THE ORACLE OUTSIDE THE GPU LOCK: a Godot launch takes the extension lock first, so holding this one
# across it deadlocks against a lane holding the other. lasim takes the GPU lock alone.
la_lasim_oracle_run "$WORK" 2 || exit 2

la_gpu_lock
lock_rc=$?
[ "$lock_rc" -eq 1 ] && { echo "check_derive_safe_math: the GPU lock did not come free." >&2; exit 2; }
for arm in "once 1" "twice 2"; do
	set -- $arm
	if ! la_lasim --load "$WORK/field.lafs" --plan "$WORK/plan_derive.lapl" --passes derive \
			--steps "$2" --mirrors "$WORK/$1.lafs" > "$WORK/$1.log" 2>&1; then
		echo "check_derive_safe_math: lasim did not complete the $1 arm." >&2
		tail -20 "$WORK/$1.log" >&2
		exit 2
	fi
done
[ "$lock_rc" -eq 0 ] && la_gpu_unlock
lock_rc=1

python3 - "$WORK" "$CEIL" <<'PY'
import math, os, struct, sys

work, ceiling = sys.argv[1], int(sys.argv[2])
# The bounds the two gates that own the rest of the state declare, on the channels they hand over here.
TOL_K = 1.0e-3
TOL_REL = 1.0e-5
ABSOLUTE = {"temp": TOL_K, "temp_lith": TOL_K}
WATCHED = ("pressure", "p_fluid", "k_cond", "temp", "temp_lith")

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

a_cells, a_names, a_body = mirrors(os.path.join(work, "once.lafs"))
b_cells, b_names, b_body = mirrors(os.path.join(work, "twice.lafs"))
g_cells, g_names, g_body = mirrors(os.path.join(work, "godot_mirrors.lafs"))
if (a_cells, a_names) != (b_cells, b_names) or (a_cells, a_names) != (g_cells, g_names):
	print("check_derive_safe_math: the three write-backs do not describe one world.", file=sys.stderr)
	sys.exit(2)

red = []
examined = 0
for name in WATCHED:
	if name not in a_names:
		continue
	examined += 1
	off = a_names.index(name) * a_cells * 4
	once = struct.unpack_from("<%df" % a_cells, a_body, off)
	twice = struct.unpack_from("<%df" % a_cells, b_body, off)
	godot = struct.unpack_from("<%df" % a_cells, g_body, off)
	absolute = ABSOLUTE.get(name)
	out = 0
	worst = 0.0
	for u, v, w in zip(once, twice, godot):
		for x in (v, w):
			if u == x or (math.isnan(u) and math.isnan(x)):
				continue
			if math.isinf(u) or math.isinf(x):
				out += 1
				continue
			d = abs(u - x) if absolute is not None else abs(u - x) / max(abs(u), abs(x), 1.0)
			worst = max(worst, d)
			if d > (absolute if absolute is not None else TOL_REL):
				out += 1
	if out:
		red.append((name, out, worst, "K" if absolute is not None else "relative"))
if examined == 0:
	print("check_derive_safe_math: none of the watched channels was written back.", file=sys.stderr)
	sys.exit(2)
for name, out, worst, unit in red:
	print("  %s: %d readings past its bound, worst %s %.3g" % (name, out, unit, worst))
print("DERIVE_SAFE_MATH={\"red\":%d,\"examined\":%d,\"cap\":%d}" % (len(red), examined, ceiling))
if len(red) > ceiling:
	print("check_derive_safe_math: %d of %d channels do not survive the arithmetic, ceiling %d."
		% (len(red), examined, ceiling), file=sys.stderr)
	sys.exit(1)
sys.exit(0 if len(red) == ceiling else 3)
PY
RC=$?
case "$RC" in
	0) ;;
	3) echo "NOTE  below the ceiling — lower docs/DERIVE_SAFE_MATH_CEILING to bank it." ;;
	*) exit "$RC" ;;
esac
echo "check_derive_safe_math: OK"
exit 0
