extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## The field reduces itself. One kernel, one dispatch per LAReduceRecords row, one partial per workgroup.
## Last in the chain, so every row reads settled state.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/reduce.glsl"
const PARTIALS: String = "reduce_partials"
const GROUP: int = 64
const PC_BYTES: int = 44

var _pipe: RID = RID()
var _rows: Array = []                   # rows whose buffers exist, in dispatch order
var _sets: Array = []                   # per row: its uniform set
var _partials: RID = RID()
var _groups: int = 0
var _step: int = -1                     # field step the last dispatch reduced
var _latch_step: Dictionary = {}        # ref buffer -> field step that reference was taken at
var _failed_announced: bool = false
var _last: Dictionary = {}              # the last drain, for the query modules that read rows directly
var _folds: PackedInt32Array = PackedInt32Array()   # per row: how its workgroup partials combine
var _keys: PackedStringArray = PackedStringArray()  # per row: the key its reading publishes under
var _costs: PackedStringArray = PackedStringArray() # per row: the driver's cost key for its kind


## One partial per workgroup per row, plus one reference buffer per `ref` the rows name.
func _buffers(cc: int) -> Dictionary:
	var g: int = maxi(int(ceil(float(cc) / float(GROUP))), 1)
	var out: Dictionary = {PARTIALS: g * LAProcessSet.reduce_rows().size()}
	for row: Dictionary in LAProcessSet.reduce_rows():
		if String(row.get("ref", "")) != "":
			out[String(row["ref"])] = maxi(cc, 1)
	return out


func _setup(bufs: Dictionary, cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	if not _pipe.is_valid():
		return
	_groups = maxi(int(ceil(float(cc) / float(GROUP))), 1)
	_partials = _single(bufs, PARTIALS)
	if not _partials.is_valid():
		push_error("ReducePass: the driver allocated no \"%s\"; every reduced total is absent." % PARTIALS)
		return
	var solid: RID = _single(bufs, "solid")
	var nbr: RID = _single(bufs, "nbr")
	var vert_up: RID = _single(bufs, "vert_up")
	var vert_down: RID = _single(bufs, "vert_down")
	if not nbr.is_valid() or not vert_up.is_valid() or not vert_down.is_valid():
		push_error("ReducePass: the driver allocated no \"nbr\"/\"vert_up\"/\"vert_down\"; no row can ask "
			+ "what is beside a cell, and none can ask what is below it.")
		return
	for row: Dictionary in LAProcessSet.reduce_rows():
		var src: String = String(row["source"])
		var aux: String = String(row.get("aux", ""))
		var aux2: String = String(row.get("aux2", ""))
		var ref: String = String(row.get("ref", ""))
		var gate: String = String(row.get("gate", ""))
		var gate_aux: String = String(row.get("gate_aux", ""))
		var absent: PackedStringArray = PackedStringArray()
		for key in [src, aux, aux2, ref, gate, gate_aux]:
			if String(key) != "" and not bufs.has(String(key)):
				absent.append(String(key))
		if absent.size() > 0:
			push_error(("ReducePass: row \"%s\" names %s, which nothing allocates. Its reading is ABSENT, "
				+ "not zero, and its consumer publishes null.") % [String(row["key"]), ", ".join(absent)])
			continue
		# A row that names no aux, gate or ref binds `solid` into those slots: already bound, and read
		# through a predicate the row leaves off.
		_sets.append(_uset(_pipe, LABindings.set_for("reduce.glsl", bufs, {
			"reduce_src": _single(bufs, src),
			"reduce_aux": _single(bufs, aux) if aux != "" else solid,
			"reduce_aux2": _single(bufs, aux2) if aux2 != "" else solid,
			"reduce_ref": bufs[ref] if ref != "" else solid,
			"reduce_gate": _single(bufs, gate) if gate != "" else solid,
			"reduce_gate_aux": _single(bufs, gate_aux) if gate_aux != "" else solid,
			"reduce_partials": _partials})))
		_rows.append(row)
		_folds.append(_fold_mode(int(row["op"])))
		_keys.append(String(row["key"]))
		_costs.append(_kind(_pc(cc, row, 0)))


func dispatch(rd: RenderingDevice, ctx: Dictionary, cc: int, _groups_in: int) -> void:
	if not _dispatchable() or _sets.is_empty():
		if not _failed_announced:
			_failed_announced = true
			push_error("GPU_REQUIRED: ReducePass has no pipeline, so the conservation ledger reads nothing "
				+ "and every substance total is absent. Usual cause: reduce.glsl was never imported — run "
				+ "`godot --headless --path . --import` in this worktree.")
		return
	_step = int(ctx.get("step_index", -1))
	# A REFERENCE IS THE STATE THE WORLD WAS BUILT WITH, so a mid-seed derive takes none.
	_run(rd, ctx, cc, not bool(ctx.get("seeding", false)))


## Every row. `latch_ok` false leaves every reference where it is.
func _run(_rd: RenderingDevice, ctx: Dictionary, cc: int, latch_ok: bool) -> void:
	var usets: Array = []
	var pcs: Array = []
	var wgs: PackedInt32Array = PackedInt32Array()
	var costs: PackedStringArray = PackedStringArray()
	for r in _rows.size():
		var row: Dictionary = _rows[r]
		var ref: String = String(row.get("ref", ""))
		var latch: bool = int(row["op"]) == LAReduceRecords.Op.LATCH
		if latch and (_latch_step.has(ref) or not latch_ok):
			continue      # a reference is the state the world was built with, taken once per row
		usets.append(_sets[r])
		pcs.append(_pc(cc, row, r * _groups))
		wgs.append(_groups)
		costs.append(_costs[r])
		if latch:
			_latch_step[ref] = _step
	_driver.run(_pipe, usets, pcs, wgs, [], PackedInt32Array(), true, costs)


## A row's cost key: its op, mask, weight, aux and gate words and its nbr, which choose what a cell's lane
## does. Rows apart only in source, threshold, gate bounds or slot share one measurement.
func _kind(pc: PackedByteArray) -> String:
	return _label() + "/" + (pc.slice(4, 12) + pc.slice(20, 32) + pc.slice(40, 44)).hex_encode()


## A reduce taken BETWEEN passes: this pass runs last, so a row cannot say WHICH pass moved a total.
## Leaves every reference and `latest()` alone — arming a probe may not move what an instrument reads.
func checkpoint(rd: RenderingDevice, ctx: Dictionary, cc: int) -> Dictionary:
	if not _dispatchable() or _sets.is_empty():
		return {}
	_driver.open()
	_run(rd, ctx, cc, false)
	_driver.close()
	return _fold_rows()


## The last drained rows. Reading does not clear it: several instruments read the same reduction.
func latest() -> Dictionary:
	return _last


func _drain(_rd: RenderingDevice) -> Dictionary:
	_last = _fold_rows()
	return _last


## ONE readback of the partials buffer, folded on the device side of the boundary: a row's groups
## combined in float64, in slot order. A MIN/MAX lane that kept no cell is ABSENT, never zero.
func _fold_rows() -> Dictionary:
	if _rows.is_empty() or not _partials.is_valid() or _driver == null:
		return {}
	var out: Dictionary = _driver.fold_reduce(_partials, _folds, _keys, _groups)
	out["reduce_step"] = float(_step)
	for key in _latch_step:
		out[String(key) + "_step"] = float(_latch_step[key])
	return out


## reduce.glsl's la_identity, as the shape the driver folds it with.
func _fold_mode(op: int) -> int:
	if op == LAReduceRecords.Op.LATCH:
		return LAFieldDriver.FOLD_SKIP
	if op == LAReduceRecords.Op.MIN:
		return LAFieldDriver.FOLD_MIN
	if op == LAReduceRecords.Op.MAX or op == LAReduceRecords.Op.MAX_REL_DIFF:
		return LAFieldDriver.FOLD_MAX
	return LAFieldDriver.FOLD_SUM


# Params { uint cell_count, op, mask, base; float threshold; uint weight, has_aux, has_gate;
#          float gate_lo, gate_hi; uint nbr; } — 44 bytes.
func _pc(cc: int, row: Dictionary, base: int) -> PackedByteArray:
	var gate: String = String(row.get("gate", ""))
	var has_aux: int = 0
	if String(row.get("aux", "")) != "":
		has_aux = 2 if String(row.get("aux2", "")) != "" else 1
	var has_gate: int = 0
	if gate != "":
		has_gate = 2 if String(row.get("gate_aux", "")) != "" else 1
		has_gate += 4 if bool(row.get("gate_strict_lo", false)) else 0
		has_gate += 8 if bool(row.get("gate_both_ends", false)) else 0
	has_gate += 16 if LAReduceRecords.HELD_SOURCES.has(String(row["source"])) else 0
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(PC_BYTES)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, int(row["op"]))
	pc.encode_u32(8, int(row.get("mask", LAReduceRecords.Mask.ALL)))
	pc.encode_u32(12, base)
	pc.encode_float(16, float(row.get("threshold", 0.0)))
	# The kernel weighs each cell by ITS OWN volume; a graded grid has no one cell volume to bake in.
	pc.encode_u32(20, 1 if bool(row.get("weight", false)) else 0)
	pc.encode_u32(24, has_aux)
	pc.encode_u32(28, has_gate)
	pc.encode_float(32, float(row.get("gate_lo", -INF)))
	pc.encode_float(36, float(row.get("gate_hi", INF)))
	pc.encode_u32(40, int(row.get("nbr", LAReduceRecords.Nbr.NONE)))
	return pc
