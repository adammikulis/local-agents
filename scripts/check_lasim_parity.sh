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
. "$SCRIPT_DIR/lib_capture.sh"
require_tool python3
require_tool cmake

GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "check_lasim_parity: no godot on PATH." >&2; exit 2; }
[ -f "$ROOT/scripts/run_sim_offscreen.sh" ] || {
	echo "check_lasim_parity: run_sim_offscreen.sh missing." >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/la_lasim_parity.XXXXXX")" || {
	echo "check_lasim_parity: no writable temp directory." >&2; exit 2; }
TESTS="$ROOT/addons/local_agents/tests"
PROBE="$TESTS/zz_lasim_parity.gd"
REC_DERIVE="$TESTS/zz_lasim_rec_derive.gd"
REC_REDUCE="$TESTS/zz_lasim_rec_reduce.gd"
lock_rc=1
cleanup() {
	rm -f "$PROBE" "$PROBE.uid" "$REC_DERIVE" "$REC_DERIVE.uid" "$REC_REDUCE" "$REC_REDUCE.uid"
	rm -rf "$WORK"
	[ "$lock_rc" -eq 0 ] && la_gpu_unlock
}
trap cleanup EXIT INT TERM

# THE PASSES THEMSELVES, with one seam each that records what they built. Nothing here restates a binding
# or a row: `_uset` is handed the entries LABindings.set_for produced for that pass.
cat > "$REC_DERIVE" <<'GD'
extends "res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd"

var rec_sets: Array = []
var rec_made: Array = []


func _uset(kernel: RID, entries: Array) -> RID:
	var r: RID = super._uset(kernel, entries)
	rec_sets.append({"rid": r, "kernel": "state_derive", "entries": entries.duplicate()})
	return r


func _storage_buffer(bytes: PackedByteArray) -> RID:
	var r: RID = super._storage_buffer(bytes)
	rec_made.append(r)
	return r
GD

cat > "$REC_REDUCE" <<'GD'
extends "res://addons/local_agents/sim/material/sphere_passes/ReducePass.gd"

var rec_sets: Array = []
var rec_made: Array = []


func _uset(kernel: RID, entries: Array) -> RID:
	var r: RID = super._uset(kernel, entries)
	rec_sets.append({"rid": r, "kernel": "reduce", "entries": entries.duplicate()})
	return r


func _storage_buffer(bytes: PackedByteArray) -> RID:
	var r: RID = super._storage_buffer(bytes)
	rec_made.append(r)
	return r
GD

cat > "$PROBE" <<'GD'
extends SceneTree

## THE ORACLE FOR scripts/check_lasim_parity.sh. A box of cells, seeded off the substance table, stepped
## by the real StateDerivePass and ReducePass; what they bound, encoded and folded is recorded so the
## native process can be handed the same plan rather than a second copy of it.

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")
const DeriveScript: GDScript = preload("res://addons/local_agents/tests/zz_lasim_rec_derive.gd")
const ReduceScript: GDScript = preload("res://addons/local_agents/tests/zz_lasim_rec_reduce.gd")

const CELL: float = 2000.0
const NX: int = 8
const NY: int = 8
const NZ: int = 8
## The rung that first declares the reduce rows, so the fold has rows to publish.
const RUNG: int = 1

var _rd: RenderingDevice = null
var _out: String = ""
var _steps: int = 2
var _fails: int = 0
var _bufs: Dictionary = {}
var _mirror_of: Dictionary = {}


func _init() -> void:
	QuietWindow.apply_if_automated()
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for i in args.size():
		var a: String = String(args[i])
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--steps="):
			_steps = maxi(int(a.substr(8)), 1)
	if _out == "":
		printerr("zz_lasim_parity: --out=DIR names where the snapshot and plan are written.")
		quit(2)
		return
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		printerr("zz_lasim_parity: no RenderingDevice, so this oracle cannot run.")
		quit(2)
		return
	_run()
	quit(2 if _fails > 0 else 0)


func _f32(n: int) -> RID:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(maxi(n, 1))
	var b: PackedByteArray = a.to_byte_array()
	return _rd.storage_buffer_create(b.size(), b)


func _i32(v: PackedInt32Array) -> RID:
	var b: PackedByteArray = v.to_byte_array()
	return _rd.storage_buffer_create(maxi(b.size(), 4), b)


func _bytes_buffer(b: PackedByteArray) -> RID:
	return _rd.storage_buffer_create(maxi(b.size(), 4), b)


func _upload(rid: RID, vals: PackedFloat32Array) -> void:
	var b: PackedByteArray = vals.to_byte_array()
	_rd.buffer_update(rid, 0, b.size(), b)


func _run() -> void:
	LAProcessSet.declare(RUNG)
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build(NX, NY, NZ, CELL, Vector3.ZERO)
	var cc: int = grid.cell_count
	for name in LAChannels.channels():
		_bufs[String(name)] = _f32(cc)
		_mirror_of[String(name)] = true
	for name in LAChannels.derived_buffers():
		_bufs[String(name)] = _f32(cc)
		_mirror_of[String(name)] = true
	_bufs["nbr"] = _i32(grid.neighbours)
	_bufs["slot_off"] = _i32(grid.slot_off)
	_bufs["face_partner"] = _i32(grid.partners)
	var ghost: PackedInt32Array = PackedInt32Array()
	ghost.resize(grid.neighbours.size())
	ghost.fill(-1)
	_bufs["ghost"] = _i32(ghost)
	_bufs["cell_edge"] = _bytes_buffer(grid.cell_edges().to_byte_array())
	_bufs["pos"] = _bytes_buffer(grid.centres.to_byte_array())
	_bufs["gravity"] = _f32(cc * 3)
	_bufs["ground_d"] = _f32(cc)

	var derive: RefCounted = DeriveScript.new()
	var reduce: RefCounted = ReduceScript.new()
	for p in [derive, reduce]:
		var want: Dictionary = p._buffers(cc)
		for name in want:
			if _bufs.has(String(name)):
				continue
			var spec: Variant = want[name]
			_bufs[String(name)] = _f32(int(spec["n"]) if spec is Dictionary else int(spec))
	# NO SOLVED GRAVITY IN A BOX WITH NO GRAVITY PASS, so no cell has a vertical neighbour: -1 is the
	# absence the kernels read, where a zero fill would claim every cell sits on cell 0.
	var none: PackedInt32Array = PackedInt32Array()
	none.resize(cc)
	none.fill(-1)
	for name in ["vert_up", "vert_down"]:
		if _bufs.has(String(name)):
			_rd.free_rid(_bufs[String(name)])
		_bufs[String(name)] = _i32(none)

	var missing: PackedStringArray = PackedStringArray()
	for kernel in ["state_derive.glsl", "reduce.glsl"]:
		for name in LABindings.IN_KERNEL[kernel]:
			if not _bufs.has(String(name)) and String(name) != "derive_props" \
					and not String(name).begins_with("reduce_"):
				missing.append(String(name))
	if missing.size() > 0:
		printerr("zz_lasim_parity: nothing allocates %s." % ", ".join(missing))
		_fails += 1
		return

	_seed(cc)

	for p in [derive, reduce]:
		p.grid_dims = Vector3i(NX, NY, NZ)
		p.grid_cell_size = CELL
		p.grid_origin = Vector3.ZERO
		p.face_count = grid.neighbours.size()
		p.ghost_count = 0
		p.setup(_rd, _bufs, cc)

	var seeded: PackedStringArray = LAChannels.channels()
	seeded.append_array(PackedStringArray(["pressure", "p_fluid"]))
	if not _snapshot(grid, cc, seeded, "field.lafs"):
		return
	var sets: Array = derive.rec_sets + reduce.rec_sets
	var before: Array = _plan_buffers(sets, cc)

	var groups: int = int(ceil(float(cc) / 64.0))
	var steps: Array = []
	for s in _steps:
		var ctx: Dictionary = {"cell_size": CELL, "centre": Vector3.ZERO, "spin": Vector3.ZERO,
			"spin_rate_rad_s": 0.0, "sea_radius": 0.0, "gravity_self": 0.0, "step_index": float(s),
			"dt_s": 1.0, "seeding": false}
		var cl: int = _rd.compute_list_begin()
		derive.dispatch(_rd, cl, ctx, cc, groups)
		reduce.dispatch(_rd, cl, ctx, cc, groups)
		_rd.compute_list_end()
		_rd.submit()
		_rd.sync()
		steps.append(_dispatched(derive, reduce, ctx, cc, groups, s))

	var rows: Dictionary = reduce._drain(_rd)
	# ARM B's plan: the whole run, off the buffers as they stood before the first step.
	_write_plan("plan.lapl", before, sets, steps, reduce, cc)
	# ARM A's plan: the last step's reduce alone, off the buffers as they stand after it, so the
	# references the latch rows took are the ones this fold was taken against.
	var after: Array = _plan_buffers(sets, cc)
	var last: Array = []
	for d in steps[steps.size() - 1]:
		if String(d["kernel"]) == "reduce":
			last.append(d)
	_write_plan("plan_reduce.lapl", after, sets, [last], reduce, cc)
	_write_mirrors(grid, cc, after)

	# THE DOUBLE THE DRIVER FOLDED, BIT FOR BIT: every decimal rendering GDScript offers rounds, and a
	# comparison against a rounded number cannot be exact.
	var pub: PackedStringArray = PackedStringArray()
	var published: int = 0
	for key in rows:
		var k: String = String(key)
		if k == "reduce_step" or k.ends_with("_step"):
			continue
		var bits: PackedByteArray = PackedByteArray()
		bits.resize(8)
		bits.encode_double(0, float(rows[key]))
		pub.append("\"%s\":\"%s\"" % [k, bits.hex_encode()])
		published += 1
	print("GODOT_ROWS={%s}" % ",".join(pub))
	print("GODOT_PARITY={\"cells\":%d,\"steps\":%d,\"rows\":%d,\"buffers\":%d,\"sets\":%d,\"reduce\":%d}"
		% [cc, _steps, published, before.size(), sets.size(), last.size()])


## A column of air over rock, at pressures and enthalpies the substance table states, so the derive is
## asked a question it has an answer to rather than one about an empty box.
func _seed(cc: int) -> void:
	var full_h2o: float = LASubstances.full_mol_m3("h2o")
	var full_sil: float = LASubstances.full_mol_m3("silicate")
	var molar: PackedFloat32Array = LAMatterChannels.molar_masses()
	var m_sil: float = molar[LAMatterChannels.CHANNELS.find("silicate")]
	var h2o: PackedFloat32Array = PackedFloat32Array()
	var sil: PackedFloat32Array = PackedFloat32Array()
	var n2: PackedFloat32Array = PackedFloat32Array()
	var e: PackedFloat32Array = PackedFloat32Array()
	var pres: PackedFloat32Array = PackedFloat32Array()
	for c in cc:
		var f: float = float(c) / float(maxi(cc - 1, 1))
		var p: float = 101325.0 * pow(10.0, 3.0 * f)
		pres.append(p)
		h2o.append(f * full_h2o)
		sil.append((1.0 - f) * full_sil)
		n2.append(40.0 * (1.0 - f))
		var kg_w: float = f * full_h2o * LAPhysical.MOLAR_MASS_WATER_KG_MOL
		var kg_r: float = sil[c] * m_sil
		e.append(kg_w * LASubstances.enthalpy_at("h2o", 15.0, p)
			+ kg_r * LASubstances.enthalpy_at("silicate", 15.0, p))
	_upload(_bufs["h2o"], h2o)
	_upload(_bufs["silicate"], sil)
	_upload(_bufs["n2"], n2)
	_upload(_bufs["e_j_m3"], e)
	_upload(_bufs["pressure"], pres)


## The dispatches the two passes just issued: the derive's block out of the restate it published and the
## detect block it derives from that, then the reduce row blocks the pass encodes, taking which latch rows
## ran this step off the pass's own record of when it latched.
func _dispatched(derive: RefCounted, reduce: RefCounted, ctx: Dictionary, cc: int, groups: int,
		step: int) -> Array:
	var out: Array = []
	var restate: Dictionary = ctx.get("restate", {})
	var pc: PackedByteArray = restate.get("pc", PackedByteArray())
	if pc.is_empty():
		printerr("zz_lasim_parity: the derive published no push-constant block.")
		_fails += 1
		return out
	var detect: PackedByteArray = pc.duplicate()
	detect.encode_u32(derive.PC_DETECT, 1)
	out.append({"kernel": "state_derive", "uset": derive._set, "groups": groups, "push": pc})
	out.append({"kernel": "state_derive", "uset": derive._set, "groups": groups, "push": detect})
	var rows: Array = reduce._rows
	var latched: Dictionary = reduce._latch_step
	for r in rows.size():
		var row: Dictionary = rows[r]
		if int(row["op"]) == LAReduceRecords.Op.LATCH \
				and int(latched.get(String(row.get("ref", "")), -1)) != step:
			continue
		out.append({"kernel": "reduce", "uset": (reduce._sets as Array)[r], "groups": reduce._groups,
			"push": reduce._pc(cc, row, r * reduce._groups)})
	return out


## A moment of the field in LAFieldSnapshot's own layout.
func _snapshot(grid: LAVoxelGrid, cc: int, names: PackedStringArray, file: String) -> bool:
	var store: LAFieldSnapshot = LAFieldSnapshot.new()
	store.bind(_rd, _bufs, names, cc, grid)
	var handle: int = store.capture()
	if handle < 0:
		printerr("zz_lasim_parity: the capture for %s read nothing back." % file)
		_fails += 1
		return false
	var f: FileAccess = FileAccess.open("%s/%s" % [_out, file], FileAccess.WRITE)
	if f == null:
		printerr("zz_lasim_parity: cannot write %s/%s" % [_out, file])
		_fails += 1
		return false
	f.store_buffer(store.serialize(handle))
	return true


## The derived state after the last step, in the order the plan carries it, so the native run's own
## write-back compares against this file channel for channel.
func _write_mirrors(grid: LAVoxelGrid, cc: int, buffers: Array) -> void:
	var names: PackedStringArray = PackedStringArray()
	for b in buffers:
		if int(b["kind"]) == 0:
			names.append(String(b["name"]))
	_snapshot(grid, cc, names, "godot_mirrors.lafs")


## Every buffer the recorded sets bind, read back as it stands, named where the field names it.
func _plan_buffers(sets: Array, cc: int) -> Array:
	var by_rid: Dictionary = {}
	for name in _bufs:
		by_rid[_bufs[name]] = String(name)
	var out: Array = []
	var seen: Dictionary = {}
	for s in sets:
		for e in s["entries"]:
			var rid: RID = e[1]
			if seen.has(rid):
				continue
			seen[rid] = true
			var bytes: PackedByteArray = _rd.buffer_get_data(rid)
			var name: String = String(by_rid.get(rid, "pass_buffer_%d" % out.size()))
			out.append({"name": name, "elems": bytes.size() / 4, "bytes": bytes, "rid": rid,
				"kind": 0 if (_mirror_of.has(name) and bytes.size() / 4 == cc) else 1})
	return out


func _put_str(f: FileAccess, s: String) -> void:
	var b: PackedByteArray = s.to_utf8_buffer()
	f.store_32(b.size())
	f.store_buffer(b)


func _write_plan(file: String, buffers: Array, sets: Array, steps: Array, reduce: RefCounted,
		cc: int) -> void:
	var index: Dictionary = {}
	for i in buffers.size():
		index[buffers[i]["rid"]] = i
	var set_index: Dictionary = {}
	for i in sets.size():
		set_index[sets[i]["rid"]] = i
	var f: FileAccess = FileAccess.open("%s/%s" % [_out, file], FileAccess.WRITE)
	if f == null:
		printerr("zz_lasim_parity: cannot write %s/%s" % [_out, file])
		_fails += 1
		return
	f.store_32(0x4C50414C)      # 'LAPL'
	f.store_32(1)
	f.store_32(cc)
	f.store_32(reduce._groups)
	f.store_32(buffers.size())
	for b in buffers:
		_put_str(f, String(b["name"]))
		f.store_32(int(b["elems"]))
		f.store_32(int(b["kind"]))
		f.store_buffer(b["bytes"])
	f.store_32(sets.size())
	for s in sets:
		_put_str(f, String(s["kernel"]))
		f.store_32((s["entries"] as Array).size())
		for e in s["entries"]:
			f.store_32(int(e[0]))
			f.store_32(int(index[e[1]]))
	f.store_32(steps.size())
	for step in steps:
		f.store_32((step as Array).size())
		for d in step:
			_put_str(f, String(d["kernel"]))
			f.store_32(int(set_index[d["uset"]]))
			f.store_32(int(d["groups"]))
			var push: PackedByteArray = d["push"]
			f.store_32(push.size())
			f.store_buffer(push)
	var keys: PackedStringArray = reduce._keys
	f.store_32(keys.size())
	for i in keys.size():
		_put_str(f, String(keys[i]))
		f.store_32(int(reduce._folds[i]))
GD

la_lasim_build || exit 2

STEPS="${LA_PARITY_STEPS:-2}"
GODOT_LOG="$WORK/godot.log"
LA_DONE_RE='^GODOT_PARITY=' "$ROOT/scripts/run_sim_offscreen.sh" --path "$ROOT" \
	-s "res://addons/local_agents/tests/zz_lasim_parity.gd" -- \
	"--out=$WORK" "--steps=$STEPS" > "$GODOT_LOG" 2>&1
grep -E '^GODOT_PARITY=' "$GODOT_LOG" || true
grep -q '^GODOT_PARITY=' "$GODOT_LOG" || {
	echo "check_lasim_parity: the Godot oracle published no reading, so there is nothing to compare." >&2
	tail -25 "$GODOT_LOG" >&2
	exit 2
}
for f in field.lafs plan.lapl plan_reduce.lapl godot_mirrors.lafs; do
	[ -s "$WORK/$f" ] || { echo "check_lasim_parity: the oracle wrote no $f." >&2; exit 2; }
done

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

# ARM C: one bit of one recorded push-constant block, which is where a plan's masks and row selectors
# live. lasim replays the plan, so a fold blind to this is blind to every plan defect.
python3 - "$WORK/plan_reduce.lapl" "$WORK/plan_mutated.lapl" <<'PY'
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
raw[found] ^= 0x01
open(sys.argv[2], 'wb').write(bytes(raw))
PY
[ -s "$WORK/plan_mutated.lapl" ] || {
	echo "check_lasim_parity: the plan could not be mutated, so this gate has no positive control." >&2
	exit 2
}
if ! la_lasim --load "$WORK/godot_mirrors.lafs" --plan "$WORK/plan_mutated.lapl" --passes reduce \
		--steps 1 --report > "$WORK/mutant.log" 2>&1; then
	echo "check_lasim_parity: the mutated plan did not run; the control proves nothing." >&2
	tail -20 "$WORK/mutant.log" >&2
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
if native is None or mutant is None:
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
		x, y = float(a[k]), float(b[k])
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

# ARM B. float32 unit roundoff is 2^-24; Godot's Metal driver compiles with fast math and la::Device with
# MTLMathModeSafe, so one side may reassociate or contract an expression the other evaluates in order.
# The derive's per-cell expression tree is at most ~32 roundings deep, so 2^-19 bounds their difference.
BOUND = 2.0 ** -19
# state_derive.glsl's (T, p) solve is pinned by its own stopping criterion, not by roundoff. Kelvin, the
# resolution check_derive_fixed_point.sh declares for the same solver.
SOLVED_K = 1.0e-3
SOLVED = {"temp": SOLVED_K, "temp_lith": SOLVED_K}
# The solve stops on a residual in pressure units, which bounds no pressure; that claim is
# check_derive_fixed_point.sh's.
UNPINNED = ("pressure", "p_fluid")

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
		if name in UNPINNED:
			continue
		off = i * g_cells * 4
		a = struct.unpack_from("<%df" % g_cells, g_body, off)
		b = struct.unpack_from("<%df" % g_cells, n_body, off)
		absolute = SOLVED.get(name)
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
			if d > (absolute if absolute is not None else BOUND):
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
		"check_derive_fixed_point.sh, which owns the solve's fixed point."
		% (compared, ", ".join(UNPINNED)))

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
