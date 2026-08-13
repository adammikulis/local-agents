extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## The field reduces itself. One kernel, one dispatch per LAReduceRecords row, one partial per workgroup.
## Last in the chain, so every row reads settled state.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/reduce.glsl"
const PARTIALS: String = "reduce_partials"
const CRUST_REF: String = "crust_ref"
const GROUP: int = 64
const PC_BYTES: int = 32

var _pipe: RID = RID()
var _rows: Array = []                   # rows whose buffers exist, in dispatch order
var _sets: Array = []                   # per row: [set(parity 0), set(parity 1)]
var _partials: RID = RID()
var _groups: int = 0
var _step: int = -1                     # field step the last dispatch reduced
var _latch_step: int = -1               # field step the crust reference was taken at
var _failed_announced: bool = false


## One partial per workgroup per row, plus the crust reference the diff row is taken from.
func _buffers(cc: int) -> Dictionary:
	var g: int = maxi(int(ceil(float(cc) / float(GROUP))), 1)
	return {PARTIALS: g * LAReduceRecords.rows().size(), CRUST_REF: maxi(cc, 1)}


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
	for row: Dictionary in LAReduceRecords.rows():
		var src: String = String(row["source"])
		var aux: String = String(row.get("aux", ""))
		var ref: String = String(row.get("ref", ""))
		var absent: PackedStringArray = PackedStringArray()
		for key in [src, aux, ref]:
			if String(key) != "" and not bufs.has(String(key)):
				absent.append(String(key))
		if absent.size() > 0:
			push_error(("ReducePass: row \"%s\" names %s, which nothing allocates. Its reading is ABSENT, "
				+ "not zero, and its consumer publishes null.") % [String(row["key"]), ", ".join(absent)])
			continue
		var per_parity: Array = [RID(), RID()]
		for p in 2:
			per_parity[p] = _uset(_pipe, [
				[1, _half(bufs, src, p, false)],
				[2, _half(bufs, aux, p, false) if aux != "" else solid],
				[3, solid],
				[4, _partials],
				[5, bufs[ref] if ref != "" else solid]])
		_sets.append(per_parity)
		_rows.append(row)


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, _groups_in: int) -> void:
	if not _dispatchable() or _sets.is_empty():
		if not _failed_announced:
			_failed_announced = true
			push_error("GPU_REQUIRED: ReducePass has no pipeline, so the conservation ledger reads nothing "
				+ "and every substance total is absent. Usual cause: reduce.glsl was never imported — run "
				+ "`godot --headless --path . --import` in this worktree.")
		return
	_step = int(ctx.get("step_index", -1))
	var cell_m3: float = pow(_ctx_cell_size(ctx), 3.0)
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	for r in _rows.size():
		var row: Dictionary = _rows[r]
		var latch: bool = int(row["op"]) == LAReduceRecords.Op.LATCH
		if latch and _latch_step >= 0:
			continue      # the reference is the crust the world was built with, taken once
		rd.compute_list_bind_uniform_set(cl, _sets[r][parity], 0)
		var pc: PackedByteArray = _pc(cc, row, r * _groups, cell_m3)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, _groups, 1, 1)
		rd.compute_list_add_barrier(cl)
		if latch:
			_latch_step = _step


## One readback of the partials buffer; each row's groups summed in float64, in slot order.
func _drain(rd: RenderingDevice) -> Dictionary:
	var out: Dictionary = {}
	if _rows.is_empty() or not _partials.is_valid():
		return out
	var raw: PackedFloat32Array = rd.buffer_get_data(_partials).to_float32_array()
	for r in _rows.size():
		var row: Dictionary = _rows[r]
		if int(row["op"]) == LAReduceRecords.Op.LATCH:
			continue
		var base: int = r * _groups
		if base + _groups > raw.size():
			continue
		var acc: float = 0.0
		for g in _groups:
			acc += raw[base + g]
		out[String(row["key"])] = acc
	out["reduce_step"] = float(_step)
	out["crust_ref_step"] = float(_latch_step)
	return out


# Params { uint cell_count, op, mask, base; float threshold, weight; uint has_aux, pad0; } — 32 bytes.
func _pc(cc: int, row: Dictionary, base: int, cell_m3: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(PC_BYTES)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, int(row["op"]))
	pc.encode_u32(8, int(row.get("mask", LAReduceRecords.Mask.ALL)))
	pc.encode_u32(12, base)
	pc.encode_float(16, float(row.get("threshold", 0.0)))
	pc.encode_float(20, cell_m3 if bool(row.get("weight", false)) else 1.0)
	pc.encode_u32(24, 1 if String(row.get("aux", "")) != "" else 0)
	pc.encode_u32(28, 0)
	return pc
