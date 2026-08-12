extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## The mycelium mat over the dead organic pool. Fertility diffusion and the shock front are
## LATransportRecords rows and run in TransportPass.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/fungus_sphere3d.glsl"

const CellList = preload("res://addons/local_agents/sim/material/sphere_passes/CellListPass.gd")

## The kernel writes its OUT half, so a cell left off the list must already hold the value it would write.
const CELL_ROWS: Array = [{
	"label": "fungus",
	"idx": "active_idx_fungus", "args": "active_args_fungus",
	"prim": "fungus", "prim_half": CellList.Half.LIVE,
	"back": true, "aux": "detritus", "halo": true,
	"open_only": false, "inclusive": false,
	"thr": 0.0, "aux_thr": 0.0,
}]

var _cells: RefCounted = null
var _args: RID = RID()
var _pipe: RID = RID()
var _set: Array = [RID(), RID()]


func _setup(bufs: Dictionary, cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)

	# This pass owns its compactor: the list must be built AFTER ReactionsPass wrote detritus, so a cell
	# that just received litter is in it the same step.
	_cells = CellList.new()
	_cells.rows = CELL_ROWS
	_cells.setup(_rd, bufs, cc)
	_args = _cells.args_rid("fungus")

	for p in 2:
		_set[p] = _uset(_pipe, [
			[0, _half(bufs, "fungus", p, false)],
			[1, _half(bufs, "fungus", p, true)],
			[2, _single(bufs, "detritus")],
			[3, _single(bufs, "active_idx_fungus")],
			[4, _args],
			[5, _half(bufs, "temp", p, false)],
			[6, _half(bufs, "moisture", p, false)],
			[8, _single(bufs, "solid")],
			[9, _single(bufs, "fuel")],
			[15, _single(bufs, "nbr")],
			[32, _single(bufs, "org_h")],
			[33, _single(bufs, "org_o")],
			[40, _single(bufs, "cell_vol")]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable() or not _args.is_valid():
		return
	if _cells != null:
		_cells.dispatch(rd, cl, parity, ctx, cc, groups)
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
	var pc: PackedByteArray = _pc(cc, float(ctx.get("precip", 0.0)))
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch_indirect(cl, _args, 0)
	rd.compute_list_add_barrier(cl)


## The compactor is a pass in its own right and owns its RIDs, so it is disposed before the base frees ours.
func dispose(rd: RenderingDevice) -> void:
	if _cells != null:
		_cells.dispose(rd)
		_cells = null
	_args = RID()
	super.dispose(rd)


# --- helpers ---------------------------------------------------------------------------------------------

## { uint cell_count, pad0, pad1, pad2; float precip, fresh_h_per_c, fresh_o_per_c, pad5; } — 32 bytes.
func _pc(cc: int, precip: float) -> PackedByteArray:
	var b: PackedByteArray = PackedInt32Array([cc, 0, 0, 0]).to_byte_array()
	b.append_array(PackedFloat32Array([precip, LASubstances.fresh_litter_per_carbon("H"),
		LASubstances.fresh_litter_per_carbon("O"), 0.0]).to_byte_array())
	return b
