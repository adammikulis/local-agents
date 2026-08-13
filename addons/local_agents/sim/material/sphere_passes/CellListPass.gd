extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Compacted active-cell lists + indirect dispatch, one ROW per gated channel. A row's predicate reproduces
## its consumer kernel's own no-op condition, so a cell left out of the list is one that kernel would have
## left unchanged, and the consumer may dispatch indirectly over the list instead of the whole grid.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/cell_list_sphere3d.glsl"

enum Pass { RESET = 0, APPEND = 1, ARGS = 2 }
enum Half { LIVE = 0, BACK = 1 }
## Predicate terms; the kernel's F_* defines are generated from this enum.
enum Flag { OPEN_ONLY = 1, INCLUSIVE = 2, BACK = 4, HALO = 8, AUX = 16 }
## Args-buffer layout, shared with the kernel: 0-2 are the uvec3 an indirect dispatch reads, 3 is the
## atomic list length. SLOTS is the buffer's element count.
enum Arg { GROUPS_X = 0, GROUPS_Y = 1, GROUPS_Z = 2, LIST_COUNT = 3, SLOTS = 8 }


## Row keys: label · idx/args driver buffer keys · prim channel + half · back/aux/halo terms · thresholds.
## MELT reproduces transport.glsl's FILM row: no melt share, or cemented into rock, and it does not write.
## HALO adds the receivers of a molten cell's outflow to the list beside its donors.
static func rows() -> Array:
	return [
		{"label": "melt", "idx": "melt_list_idx", "args": "melt_list_args",
			"flag": "melt_list_flag",
			"prim": "silicate_melt", "prim_half": Half.LIVE, "thr": 0.0, "inclusive": false,
			"open_only": true, "back": false, "halo": true, "aux": "", "aux_thr": 0.0},
	]


## The three buffer keys of one row, or an empty dictionary for a label no row carries.
static func list_buffers(label: String) -> Dictionary:
	for row: Dictionary in rows():
		if String(row["label"]) == label:
			return {"idx": String(row["idx"]), "args": String(row["args"]),
				"flag": String(row["flag"])}
	return {}


var _rows: Array = []
var _pipe: RID = RID()
var _sets: Array = []                   # per row: [set(parity 0), set(parity 1)]
var _args_rid: Array = []               # per row: dispatch-indirect args RID
var _flags: PackedInt32Array = PackedInt32Array()
var _failed_announced: bool = false     # so the GPU_REQUIRED error below fires once, not 60x a second


## The compacted index buffer is one entry per cell; the args buffer is what an indirect dispatch reads.
func _buffers(cc: int) -> Dictionary:
	var out: Dictionary = {}
	for row: Dictionary in rows():
		out[String(row["idx"])] = cc
		out[String(row["flag"])] = cc
		out[String(row["args"])] = {"n": int(Arg.SLOTS), "indirect": true}
	return out


## Cells the last built list holds, per row.
func _drain(rd: RenderingDevice) -> Dictionary:
	var out: Dictionary = {}
	for r in _rows.size():
		var raw: PackedByteArray = rd.buffer_get_data(_args_rid[r])
		if raw.size() < int(Arg.SLOTS) * 4:
			continue
		out[String(_rows[r]["label"]) + "_list_cells"] = float(raw.to_int32_array()[int(Arg.LIST_COUNT)])
	return out


func _setup(bufs: Dictionary, _cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	_rows = rows()

	var solid: RID = _single(bufs, "solid")
	var nbr: RID = _single(bufs, "nbr")
	for row: Dictionary in _rows:
		var idx_key: String = String(row["idx"])
		var args_key: String = String(row["args"])
		var flag_key: String = String(row["flag"])
		if not bufs.has(idx_key) or not bufs.has(args_key) or not bufs.has(flag_key):
			push_error("CellListPass: driver did not allocate %s/%s/%s"
				% [idx_key, args_key, flag_key])
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
		var prim: String = String(row["prim"])
		var prim_back: bool = int(row["prim_half"]) == Half.BACK
		var per_parity: Array = [RID(), RID()]
		for p in 2:
			var aux: RID = _half(bufs, aux_key, p, false) if aux_key != "" else solid
			per_parity[p] = _uset(_pipe, [
				[1, _half(bufs, prim, p, prim_back)],
				[2, solid],
				[3, _half(bufs, prim, p, not prim_back)],
				[4, bufs[idx_key]],
				[5, bufs[args_key]],
				[6, aux],
				[7, bufs[flag_key]],
				[15, nbr]])
		_sets.append(per_parity)


func dispatch(rd: RenderingDevice, cl: int, parity: int, _ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable() or _sets.is_empty():
		if not _failed_announced:
			_failed_announced = true
			push_error("GPU_REQUIRED: CellListPass has no pipeline, so every list is empty and a kernel "
				+ "dispatching indirectly over one processes ZERO cells. Any result from this run is void. "
				+ "Usual cause: cell_list_sphere3d.glsl was never imported — run "
				+ "`godot --headless --path . --import` in this worktree.")
		return
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	for r in _sets.size():
		rd.compute_list_bind_uniform_set(cl, _sets[r][parity], 0)
		var flags: int = _flags[r]
		var thr: float = float(_rows[r]["thr"])
		var aux_thr: float = float(_rows[r]["aux_thr"])
		# 0. RESET the counter (one thread; the other 63 return immediately).
		_record(rd, cl, _pc(cc, Pass.RESET, flags, thr, aux_thr), 1)
		# 1. APPEND — the one remaining full-grid dispatch.
		_record(rd, cl, _pc(cc, Pass.APPEND, flags, thr, aux_thr), groups)
		# 2. ARGS — publish groups_x = ceil(count / 64) for the consumer's indirect dispatch.
		_record(rd, cl, _pc(cc, Pass.ARGS, flags, thr, aux_thr), 1)


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
