#!/usr/bin/env bash
# THE ORACLE THE NATIVE ARMS ARE MEASURED AGAINST: a box stepped by the real StateDerivePass and
# ReducePass, which record the plan they produced, so lasim replays the field rather than a copy of it.
# One declaration: a gate writing its own oracle measures against a different world than its neighbour.
#   la_lasim_oracle_write / _clean      put the probes in tests/ and take them out again
#   la_lasim_oracle_run <work> <steps>  leaves the snapshots and plans in <work>. 0 ran * 2 could not.

LA_ORACLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LA_ORACLE_TESTS="$LA_ORACLE_ROOT/addons/local_agents/tests"
LA_ORACLE_PROBE="$LA_ORACLE_TESTS/zz_lasim_parity.gd"
LA_ORACLE_REC_DERIVE="$LA_ORACLE_TESTS/zz_lasim_rec_derive.gd"
LA_ORACLE_REC_REDUCE="$LA_ORACLE_TESTS/zz_lasim_rec_reduce.gd"

la_lasim_oracle_clean() {
	rm -f "$LA_ORACLE_PROBE" "$LA_ORACLE_PROBE.uid" \
		"$LA_ORACLE_REC_DERIVE" "$LA_ORACLE_REC_DERIVE.uid" \
		"$LA_ORACLE_REC_REDUCE" "$LA_ORACLE_REC_REDUCE.uid"
}

la_lasim_oracle_write() {
PROBE="$LA_ORACLE_PROBE"
REC_DERIVE="$LA_ORACLE_REC_DERIVE"
REC_REDUCE="$LA_ORACLE_REC_REDUCE"
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
	# The solve's own verdict rides with the state it produced: a cell that gave up is not a fixed point
	# of anything, and a comparison blind to which cells those are compares two failures.
	_mirror_of["unconverged"] = true
	# And the stiffness the pressure was read against: p comes off a difference of two nearly-equal
	# volumes over a compressibility, so what float32 can resolve of it is 2^-23 times this.
	_mirror_of["k_cond"] = true
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
	# THE DERIVE ALONE, off the same buffers: check_derive_fixed_point.sh replays it for one step and
	# for two, and a derive that is a function of the cell returns the same state either way.
	var derive_only: Array = []
	for step in steps:
		var pass_only: Array = []
		for d in step:
			if String(d["kernel"]) == "state_derive":
				pass_only.append(d)
		derive_only.append(pass_only)
	_write_plan("plan_derive.lapl", before, sets, derive_only, reduce, cc)
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
		# Gas stands only where a fluid leaves it room: a cell full of rock holds none.
		n2.append(40.0 * (1.0 - f) if f > 0.0 else 0.0)
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

}

la_lasim_oracle_run() {  # <work> <steps>
	local WORK="$1"
	local STEPS="$2"
	local GODOT_LOG="$WORK/godot.log"
	LA_DONE_RE='^GODOT_PARITY=' "$LA_ORACLE_ROOT/scripts/run_sim_offscreen.sh" \
		--path "$LA_ORACLE_ROOT" -s "res://addons/local_agents/tests/zz_lasim_parity.gd" -- \
		"--out=$WORK" "--steps=$STEPS" > "$GODOT_LOG" 2>&1
	grep -E '^GODOT_PARITY=' "$GODOT_LOG" || true
	grep -q '^GODOT_PARITY=' "$GODOT_LOG" || {
		echo "lib_lasim_oracle: the Godot oracle published no reading." >&2
		tail -25 "$GODOT_LOG" >&2
		return 2
	}
	local f
	for f in field.lafs plan.lapl plan_derive.lapl plan_reduce.lapl godot_mirrors.lafs; do
		[ -s "$WORK/$f" ] || { echo "lib_lasim_oracle: the oracle wrote no $f." >&2; return 2; }
	done
	return 0
}
