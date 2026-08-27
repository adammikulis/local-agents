extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## The field reduces itself. One kernel, one dispatch per LAReduceRecords row, one partial per workgroup.
## Last in the chain, so every row reads settled state.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/reduce.glsl"
const PARTIALS: String = "reduce_partials"
const GROUP: int = 64
const PC_BYTES: int = 48

var _pipe: RID = RID()
var _rows: Array = []                   # rows whose buffers exist, in dispatch order
var _sets: Array = []                   # per row: its uniform set
var _partials: RID = RID()
var _groups: int = 0
var _step: int = -1                     # field step the last dispatch reduced
var _latch_step: Dictionary = {}        # ref buffer -> field step that reference was taken at
var _failed_announced: bool = false
var _last: Dictionary = {}              # the last drain, for the query modules that read rows directly


## One partial per workgroup per row, plus one reference buffer per `ref` the rows name.
func _buffers(cc: int) -> Dictionary:
	var g: int = maxi(int(ceil(float(cc) / float(GROUP))), 1)
	var out: Dictionary = {PARTIALS: g * LAReduceRecords.rows().size()}
	for row: Dictionary in LAReduceRecords.rows():
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
	for row: Dictionary in LAReduceRecords.rows():
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
		_sets.append(_uset(_pipe, [
			[1, _single(bufs, src)],
			[2, _single(bufs, aux) if aux != "" else solid],
			[3, solid],
			[4, _partials],
			[5, bufs[ref] if ref != "" else solid],
			[6, _single(bufs, gate) if gate != "" else solid],
			[7, _single(bufs, gate_aux) if gate_aux != "" else solid],
			[8, _single(bufs, aux2) if aux2 != "" else solid],
			[9, nbr],
			[10, vert_up],
			[11, vert_down]]))
		_rows.append(row)


func dispatch(rd: RenderingDevice, cl: int, ctx: Dictionary, cc: int, _groups_in: int) -> void:
	if not _dispatchable() or _sets.is_empty():
		if not _failed_announced:
			_failed_announced = true
			push_error("GPU_REQUIRED: ReducePass has no pipeline, so the conservation ledger reads nothing "
				+ "and every substance total is absent. Usual cause: reduce.glsl was never imported — run "
				+ "`godot --headless --path . --import` in this worktree.")
		return
	_step = int(ctx.get("step_index", -1))
	_run(rd, cl, ctx, cc, true)


## Every row. `latch_ok` false leaves every reference where it is.
func _run(rd: RenderingDevice, cl: int, ctx: Dictionary, cc: int, latch_ok: bool) -> void:
	var cell_m: float = _ctx_cell_size(ctx)
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	for r in _rows.size():
		var row: Dictionary = _rows[r]
		var ref: String = String(row.get("ref", ""))
		var latch: bool = int(row["op"]) == LAReduceRecords.Op.LATCH
		if latch and (_latch_step.has(ref) or not latch_ok):
			continue      # a reference is the state the world was built with, taken once per row
		rd.compute_list_bind_uniform_set(cl, _sets[r], 0)
		var pc: PackedByteArray = _pc(cc, row, r * _groups, cell_m)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, _groups, 1, 1)
		rd.compute_list_add_barrier(cl)
		if latch:
			_latch_step[ref] = _step


## A reduce taken BETWEEN passes: this pass runs last, so a row cannot say WHICH pass moved a total.
## Leaves every reference and `latest()` alone — arming a probe may not move what an instrument reads.
func checkpoint(rd: RenderingDevice, ctx: Dictionary, cc: int) -> Dictionary:
	if not _dispatchable() or _sets.is_empty():
		return {}
	var cl: int = rd.compute_list_begin()
	_run(rd, cl, ctx, cc, false)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	return _fold_rows(rd)


## The last drained rows. Reading does not clear it: several instruments read the same reduction.
func latest() -> Dictionary:
	return _last


func _drain(rd: RenderingDevice) -> Dictionary:
	_last = _fold_rows(rd)
	return _last


## One readback of the partials buffer; each row's groups folded in float64, in slot order.
func _fold_rows(rd: RenderingDevice) -> Dictionary:
	var out: Dictionary = {}
	if _rows.is_empty() or not _partials.is_valid():
		return out
	var raw: PackedFloat32Array = rd.buffer_get_data(_partials).to_float32_array()
	for r in _rows.size():
		var row: Dictionary = _rows[r]
		var op: int = int(row["op"])
		if op == LAReduceRecords.Op.LATCH:
			continue
		var base: int = r * _groups
		if base + _groups > raw.size():
			continue
		var acc: float = _fold(raw, base, op)
		# A MIN/MAX lane that kept no cell returns its INFINITE identity, and no cell anywhere means no
		# measurement. An infinity at the other end is a reading: the field went non-finite. A summing
		# lane's identity is zero, and a total of zero is a reading like any other.
		if is_inf(_identity(op)) and acc == _identity(op):
			continue
		out[String(row["key"])] = acc
	out["reduce_step"] = float(_step)
	for key in _latch_step:
		out[String(key) + "_step"] = float(_latch_step[key])
	return out


## reduce.glsl's la_identity, so a lane that kept no cell is told apart from one that read an infinity.
func _identity(op: int) -> float:
	if op == LAReduceRecords.Op.MIN: return INF
	return -INF if op == LAReduceRecords.Op.MAX or op == LAReduceRecords.Op.MAX_REL_DIFF else 0.0


## The workgroup partials of one row, combined the way that row's op combines cells.
func _fold(raw: PackedFloat32Array, base: int, op: int) -> float:
	var mn: bool = op == LAReduceRecords.Op.MIN
	var mx: bool = _identity(op) == -INF
	var acc: float = _identity(op)
	for g in _groups:
		acc = minf(acc, raw[base + g]) if mn else (maxf(acc, raw[base + g]) if mx else acc + raw[base + g])
	return acc


# Params { uint cell_count, op, mask, base; float threshold, weight; uint has_aux, has_gate;
#          float gate_lo, gate_hi; uint nbr; float cell_m; } — 48 bytes.
func _pc(cc: int, row: Dictionary, base: int, cell_m: float) -> PackedByteArray:
	var gate: String = String(row.get("gate", ""))
	var has_aux: int = 0
	if String(row.get("aux", "")) != "":
		has_aux = 2 if String(row.get("aux2", "")) != "" else 1
	var has_gate: int = 0
	if gate != "":
		has_gate = 2 if String(row.get("gate_aux", "")) != "" else 1
		has_gate += 4 if bool(row.get("gate_strict_lo", false)) else 0
		has_gate += 8 if bool(row.get("gate_both_ends", false)) else 0
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(PC_BYTES)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, int(row["op"]))
	pc.encode_u32(8, int(row.get("mask", LAReduceRecords.Mask.ALL)))
	pc.encode_u32(12, base)
	pc.encode_float(16, float(row.get("threshold", 0.0)))
	pc.encode_float(20, pow(cell_m, 3.0) if bool(row.get("weight", false)) else 1.0)
	pc.encode_u32(24, has_aux)
	pc.encode_u32(28, has_gate)
	pc.encode_float(32, float(row.get("gate_lo", -INF)))
	pc.encode_float(36, float(row.get("gate_hi", INF)))
	pc.encode_u32(40, int(row.get("nbr", LAReduceRecords.Nbr.NONE)))
	pc.encode_float(44, cell_m)
	return pc
