extends RefCounted

## Compacted active-cell lists + indirect dispatch, one ROW per gated channel. A row's predicate reproduces
## its consumer kernel's own no-op condition, so a cell left out of the list is one that kernel would have
## left unchanged. Rows are supplied by whoever owns the consumer; `rows` defaults to the driver's set.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/cell_list_sphere3d.glsl"

enum Pass { RESET = 0, APPEND = 1, ARGS = 2 }
enum Half { LIVE = 0, BACK = 1 }
## Predicate terms; mirrors cell_list_sphere3d.glsl's #defines.
enum Flag { OPEN_ONLY = 1, INCLUSIVE = 2, BACK = 4, HALO = 8, AUX = 16 }

# lava_phase_sphere3d.glsl reads the list without rechecking its own floor, so this must equal that kernel's
# LAVA_MIN_MASS. Declared in docs/MODEL_PARAMETERS.md.
const LAVA_MIN_MASS: float = 0.0001

## Row keys: label · idx/args driver buffer keys · prim channel + half · back/aux/halo terms · thresholds.
## ThermalPass consumes "active_idx"/"active_args" and has no configuration seam, so the lava row is the default.
const ROWS_DEFAULT: Array = [{
	"label": "lava",
	"idx": "active_idx", "args": "active_args",
	"prim": "lava", "prim_half": Half.BACK,       # post lava_flow, exactly what lava_phase reads
	"back": false, "aux": "", "halo": false,
	"open_only": true, "inclusive": true,
	"thr": LAVA_MIN_MASS, "aux_thr": 0.0,
}]

var rows: Array = ROWS_DEFAULT

var _shader: RID = RID()
var _pipe: RID = RID()
var _sets: Array = []                   # per row: [set(parity 0), set(parity 1)]
var _args_rid: Array = []               # per row: dispatch-indirect args RID
var _flags: PackedInt32Array = PackedInt32Array()
var _failed_announced: bool = false     # so the GPU_REQUIRED error below fires once, not 60x a second


func setup(rd: RenderingDevice, bufs: Dictionary, _cc: int) -> void:
	if rd == null:
		push_error("CellListPass: null RenderingDevice")
		return

	var sf: RDShaderFile = load(KERNEL_PATH)
	if sf == null:
		push_error("CellListPass: cell_list_sphere3d.glsl failed to load (run --import after editing it)")
		return
	_shader = rd.shader_create_from_spirv(sf.get_spirv())
	if not _shader.is_valid():
		push_error("CellListPass: shader compile failed")
		return
	_pipe = rd.compute_pipeline_create(_shader)

	var solid: RID = bufs.get("solid", RID())
	var nbr: RID = bufs.get("nbr", RID())
	for row: Dictionary in rows:
		var idx_key: String = String(row["idx"])
		var args_key: String = String(row["args"])
		if not bufs.has(idx_key) or not bufs.has(args_key):
			push_error("CellListPass: driver did not allocate %s/%s" % [idx_key, args_key])
			return
		var flags: int = 0
		if bool(row["open_only"]):
			flags |= Flag.OPEN_ONLY
		if bool(row["inclusive"]):
			flags |= Flag.INCLUSIVE
		if bool(row["back"]):
			flags |= Flag.BACK
		if bool(row["halo"]):
			flags |= Flag.HALO
		var aux_key: String = String(row["aux"])
		if aux_key != "":
			flags |= Flag.AUX
		_flags.append(flags)
		_args_rid.append(bufs[args_key])
		var per_parity: Array = [RID(), RID()]
		for p in 2:
			var aux: RID = _half(bufs, aux_key, p, Half.LIVE) if aux_key != "" else solid
			per_parity[p] = _build_set(rd, [
				[1, _half(bufs, String(row["prim"]), p, int(row["prim_half"]))],
				[2, solid],
				[3, _half(bufs, String(row["prim"]), p, 1 - int(row["prim_half"]))],
				[4, bufs[idx_key]],
				[5, bufs[args_key]],
				[6, aux],
				[15, nbr]])
		_sets.append(per_parity)


func dispatch(rd: RenderingDevice, cl: int, parity: int, _ctx: Dictionary, cc: int, groups: int) -> void:
	if not _pipe.is_valid() or _sets.is_empty():
		if not _failed_announced:
			_failed_announced = true
			push_error("GPU_REQUIRED: CellListPass has no pipeline, so every gated kernel will process ZERO "
				+ "cells and neither molten rock nor shock nor fungus will evolve. Any result from this run "
				+ "is void. Usual cause: cell_list_sphere3d.glsl was never imported — run "
				+ "`godot --headless --path . --import` in this worktree.")
		return
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	for r in _sets.size():
		rd.compute_list_bind_uniform_set(cl, _sets[r][parity], 0)
		var flags: int = _flags[r]
		var thr: float = float(rows[r]["thr"])
		var aux_thr: float = float(rows[r]["aux_thr"])
		# 0. RESET the counter (one thread; the other 63 return immediately).
		_record(rd, cl, _pc(cc, Pass.RESET, flags, thr, aux_thr), 1)
		# 1. APPEND — the one remaining full-grid dispatch.
		_record(rd, cl, _pc(cc, Pass.APPEND, flags, thr, aux_thr), groups)
		# 2. ARGS — publish groups_x = ceil(count / 64) for the consumer's indirect dispatch.
		_record(rd, cl, _pc(cc, Pass.ARGS, flags, thr, aux_thr), 1)


## The dispatch-indirect args buffer for `label`, for a consumer recorded into the same compute list.
func args_rid(label: String) -> RID:
	for r in rows.size():
		if String(rows[r]["label"]) == label:
			return _args_rid[r]
	return RID()


## Free every RID this pass owns (uniform sets, pipeline, shader). `active_idx`/`active_args` are borrowed
## from the driver's `bufs` and are freed there, not here — same convention as every other pass module.
func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for per_parity: Array in _sets:
		for r in per_parity:
			if r is RID and r.is_valid():
				rd.free_rid(r)
	_sets = []
	_args_rid = []
	_flags = PackedInt32Array()
	if _pipe.is_valid():
		rd.free_rid(_pipe)
		_pipe = RID()
	if _shader.is_valid():
		rd.free_rid(_shader)
		_shader = RID()


# --- helpers ---------------------------------------------------------------------------------------------

func _record(rd: RenderingDevice, cl: int, pc: PackedByteArray, groups: int) -> void:
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)


# Params { uint cell_count; uint pass_id; uint flags; float thr; float aux_thr; uint pad0,pad1,pad2; } — 32 bytes.
func _pc(cc: int, pass_id: int, flags: int, thr: float, aux_thr: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, pass_id)
	pc.encode_u32(8, flags)
	pc.encode_float(12, thr)
	pc.encode_float(16, aux_thr)
	pc.encode_u32(20, 0)
	pc.encode_u32(24, 0)
	pc.encode_u32(28, 0)
	return pc


## PAIR channel -> the requested half at parity `p`; SINGLE channel -> its bare RID.
func _half(bufs: Dictionary, name: String, p: int, which: int) -> RID:
	var b = bufs.get(name, null)
	if b is Array and b.size() >= 2:
		return b[p] if which == Half.LIVE else b[1 - p]
	if b is RID:
		return b
	return RID()


func _build_set(rd: RenderingDevice, entries: Array) -> RID:
	var uniforms: Array = []
	for e in entries:
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(e[0])
		u.add_id(e[1])
		uniforms.append(u)
	return rd.uniform_set_create(uniforms, _shader, 0)
