#!/usr/bin/env bash
# ONE STATE PER CELL: the derive is a function of the cell's matter and energy and of nothing else. Run
# under `lasim`, at MTLMathModeSafe -- Godot compiles with fast math, and a solve stopping on a residual
# lands elsewhere under each. (A) a second derive returns the state the first wrote; (B) the same matter
# from another starting iterate returns it too; (C) the seeded world's derive writes finite state.
# EXIT 0 the derive is a function of the cell * 1 it is not * 2 could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts"
. "$SCRIPT_DIR/lib_require.sh"
. "$SCRIPT_DIR/lib_godot_lock.sh"
. "$SCRIPT_DIR/lib_lasim.sh"
. "$SCRIPT_DIR/lib_lasim_oracle.sh"
. "$SCRIPT_DIR/lib_capture.sh"
require_tool python3
require_tool cmake
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "check_derive_fixed_point: no godot on PATH." >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/la_derive_fixed.XXXXXX")" || {
	echo "check_derive_fixed_point: no writable temp directory." >&2; exit 2; }
lock_rc=1
cleanup() {
	la_lasim_oracle_clean
	rm -rf "$WORK"
	[ "$lock_rc" -eq 0 ] && la_gpu_unlock
}
trap cleanup EXIT INT TERM

la_lasim_oracle_write
la_lasim_build || exit 2
# THE ORACLE FIRST, AND OUTSIDE THE GPU LOCK: a Godot launch takes the extension lock before the GPU
# lock, so holding this one across it deadlocks against a lane holding the other. lasim takes the GPU
# lock alone. (`la_lock_order_ok` is not on this tree yet; this is the ordering it states.)
la_lasim_oracle_run "$WORK" 2 || exit 2

# THE SAME MATTER, A DIFFERENT PLACE TO START FROM. The recorded plan carries every buffer the passes
# bound, and the snapshot the pressures the seed laid; both are rewritten here so arm B hands the solve
# another iterate over a state that has not moved.
python3 - "$WORK/plan_derive.lapl" "$WORK/plan_shifted.lapl" "$WORK/field.lafs" "$WORK/field_shifted.lafs" <<'PY'
import struct, sys

def shift_plan(src, dst, names):
	raw = bytearray(open(src, "rb").read())
	at = 20
	touched = 0
	for _ in range(struct.unpack_from("<I", raw, 16)[0]):
		n = struct.unpack_from("<I", raw, at)[0]
		at += 4
		name = raw[at:at + n].decode("utf-8")
		at += n
		elems = struct.unpack_from("<I", raw, at)[0]
		at += 8
		if name in names:
			lo, hi = names[name]
			for i in range(elems):
				struct.pack_into("<f", raw, at + i * 4, lo + (hi - lo) * ((i * 37 % 101) / 100.0))
			touched += 1
		at += elems * 4
	if touched != len(names):
		sys.exit("the plan carries %d of the %d buffers arm B shifts" % (touched, len(names)))
	open(dst, "wb").write(bytes(raw))

def shift_snapshot(src, dst, names):
	raw = bytearray(open(src, "rb").read())
	if struct.unpack_from("<I", raw, 0)[0] != 0x5346414C:
		sys.exit(src + " is not a field snapshot")
	cells = struct.unpack_from("<I", raw, 8)[0]
	count = struct.unpack_from("<I", raw, 12)[0]
	at = 16
	def take():
		nonlocal at
		n = struct.unpack_from("<I", raw, at)[0]
		at += 4
		v = raw[at:at + n].decode("utf-8")
		at += n
		return v
	take()
	channels = [take() for _ in range(count)]
	body = at
	touched = 0
	for i, name in enumerate(channels):
		if name not in names:
			continue
		lo, hi = names[name]
		off = body + i * cells * 4
		for c in range(cells):
			struct.pack_into("<f", raw, off + c * 4, lo * (hi / lo) ** ((c * 53 % 97) / 96.0))
		touched += 1
	if touched != len(names):
		sys.exit("the snapshot carries %d of the %d channels arm B shifts" % (touched, len(names)))
	open(dst, "wb").write(bytes(raw))

# A temperature and a pressure the planet has, and neither the one the solve landed on.
shift_plan(sys.argv[1], sys.argv[2], {"temp": (-90.0, 2400.0), "temp_lith": (-90.0, 2400.0),
	"pressure": (1.0e3, 1.0e9), "p_fluid": (1.0e3, 1.0e9)})
shift_snapshot(sys.argv[3], sys.argv[4], {"pressure": (1.0e3, 1.0e9), "p_fluid": (1.0e3, 1.0e9)})
PY
[ -s "$WORK/plan_shifted.lapl" ] && [ -s "$WORK/field_shifted.lafs" ] || {
	echo "check_derive_fixed_point: arm B's starting iterate could not be written." >&2
	exit 2
}

la_gpu_lock
lock_rc=$?
[ "$lock_rc" -eq 1 ] && { echo "check_derive_fixed_point: the GPU lock did not come free." >&2; exit 2; }

run() {  # run <tag> <snapshot> <plan> <steps> <mirrors>
	if ! la_lasim --load "$2" --plan "$3" --passes derive --steps "$4" --mirrors "$5" \
			> "$WORK/$1.log" 2>&1; then
		echo "check_derive_fixed_point: lasim did not complete the $1 arm." >&2
		tail -25 "$WORK/$1.log" >&2
		exit 2
	fi
}
run once "$WORK/field.lafs" "$WORK/plan_derive.lapl" 1 "$WORK/once.lafs"
run twice "$WORK/field.lafs" "$WORK/plan_derive.lapl" 2 "$WORK/twice.lafs"
run shifted "$WORK/field_shifted.lafs" "$WORK/plan_shifted.lapl" 1 "$WORK/shifted.lafs"

[ "$lock_rc" -eq 0 ] && la_gpu_unlock
lock_rc=1

python3 - "$WORK" <<'PY'
import math, os, struct, sys

work = sys.argv[1]
# What a second pass may move: float32 on the pressure, and the ladder's own last bit on T. The solve
# accepts only once |dp| and |dT| between outer iterations are inside LA_STATE_TOL, so both are bounds
# on the state and not on a residual.
TOL_K = 1.0e-3
TOL_REL = 1.0e-5
ABSOLUTE = {"temp": TOL_K, "temp_lith": TOL_K}
# A pressure read off a difference of two nearly-equal volumes does not land in the same place under
# both math modes; check_derive_safe_math.sh owns those channels and ratchets them down.
SAFE_MATH = ("pressure", "p_fluid", "k_cond")

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

def compare(arm, a_path, b_path):
	a_cells, a_names, a_body = mirrors(a_path)
	b_cells, b_names, b_body = mirrors(b_path)
	if a_cells != b_cells or a_names != b_names:
		print("FAIL  %s: %d cells over %d channels against %d over %d."
			% (arm, b_cells, len(b_names), a_cells, len(a_names)), file=sys.stderr)
		return 1, 0
	moved = []
	for i, name in enumerate(a_names):
		if name in SAFE_MATH:
			continue
		off = i * a_cells * 4
		x = struct.unpack_from("<%df" % a_cells, a_body, off)
		y = struct.unpack_from("<%df" % a_cells, b_body, off)
		absolute = ABSOLUTE.get(name)
		out = 0
		worst = 0.0
		for u, v in zip(x, y):
			if u == v or (math.isnan(u) and math.isnan(v)):
				continue
			if math.isinf(u) or math.isinf(v):
				out += 1
				continue
			d = abs(u - v) if absolute is not None else abs(u - v) / max(abs(u), abs(v), 1.0)
			worst = max(worst, d)
			if d > (absolute if absolute is not None else TOL_REL):
				out += 1
		if out:
			moved.append((name, out, worst, "K" if absolute is not None else "relative"))
	if moved:
		print("FAIL  %s: %d of %d channel(s) moved:" % (arm, len(moved), len(a_names)), file=sys.stderr)
		for name, out, worst, unit in moved[:12]:
			print("      %s: %d of %d cells, worst %s %.3g" % (name, out, a_cells, unit, worst),
				file=sys.stderr)
	return len(moved), len(a_names)

# A CELL THAT GAVE UP PUBLISHES AN ITERATE, NOT A STATE, so the fixed point is asserted over a solve
# that finished.
cells, names, body = mirrors(os.path.join(work, "once.lafs"))
if "unconverged" not in names or "k_cond" not in names:
	print("check_derive_fixed_point: the mirrors carry no `unconverged` or no `k_cond`, so a cell that "
		"gave up, or one whose pressure float32 cannot resolve, would be compared as though it had "
		"solved exactly.", file=sys.stderr)
	sys.exit(2)
gave_up = struct.unpack_from("<%df" % cells, body, names.index("unconverged") * cells * 4)
spent = sum(1 for v in gave_up if v != 0.0)
if spent:
	print("FAIL  %d of %d cells spent the solve's budget without meeting its own tolerance, so their "
		"pressure is an iterate and not a state." % (spent, cells), file=sys.stderr)

bad_a, n = compare("a second derive over the state the first wrote",
	os.path.join(work, "once.lafs"), os.path.join(work, "twice.lafs"))
bad_b, _ = compare("the same matter from a different starting iterate",
	os.path.join(work, "once.lafs"), os.path.join(work, "shifted.lafs"))
if n == 0:
	print("check_derive_fixed_point: no channel was compared.", file=sys.stderr)
	sys.exit(2)
print("DERIVE_FIXED_POINT={\"channels\":%d,\"unconverged\":%d,\"moved_second_pass\":%d,"
	"\"moved_other_start\":%d,\"held_by_safe_math_gate\":%d}"
	% (n, spent, bad_a, bad_b, len(SAFE_MATH)))
if bad_a or bad_b or spent:
	print("The derive did not return the state its own matter states. It solves T at a pressure and "
		"states a pressure from that T, so the two are solved together, and neither may be read back "
		"off the state the last pass wrote.", file=sys.stderr)
	sys.exit(1)
PY
RC=$?
[ "$RC" -eq 0 ] || exit "$RC"

# THE SEEDED WORLD, not a rig's own inputs: the same derive over the matter the seed actually laid must
# write finite state in every cell. Rung 1 is the lowest that publishes the count. Off the shared lint
# capture where there is one, so a lint does not launch an engine per gate for one reading.
world="$(la_report nonfinite_cells --path "$REPO_ROOT" --rung 1 --frames 4 2>&1)"
nf="$(printf '%s\n' "$world" | sed -n "s/^nonfinite_cells  *= *//p" | head -1 \
	| sed -e "s/.*'cur': *//" -e 's/[,}].*//')"
printf 'DERIVE_SEEDED_WORLD={"nonfinite_cells":%s}\n' "${nf:-null}"
case "${nf:-}" in
	"" | *ABSENT*) echo "check_derive_fixed_point: the seeded world published no nonfinite_cells, so the" >&2
		echo "                          derive was never read over the matter the seed laid." >&2
		printf '%s\n' "$world" | tail -15 >&2
		exit 2 ;;
esac
if ! awk -v n="$nf" 'BEGIN{exit !(n == 0)}'; then
	echo "check_derive_fixed_point: the derive wrote non-finite state over the seeded world." >&2
	exit 1
fi
echo "check_derive_fixed_point: OK"
exit 0
