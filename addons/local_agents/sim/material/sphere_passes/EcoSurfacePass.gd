extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Surface ecology: fertility diffusion, the decomposer's fertility release, and the shock CA.
## nbr is the int32 cc*N_SLOTS neighbour table on binding 15; slot names come from kernels3d/neighbours.glsli.

const KDIR: String = "res://addons/local_agents/sim/material/kernels3d/"
const FERT_PATH: String = KDIR + "fert_sphere3d.glsl"
const FUNGUS_FERT_PATH: String = KDIR + "fungus_fert_sphere3d.glsl"
const SHOCK_PATH: String = KDIR + "shock_sphere3d.glsl"

const CellList = preload("res://addons/local_agents/sim/material/sphere_passes/CellListPass.gd")

## Active-cell rows for the kernel below. The predicate is that kernel's own no-op condition: shock writes
## its ping-pong OUT half, so a skipped cell must already hold the value the next step reads.
const CELL_ROWS: Array = [{
	"label": "shock",
	"idx": "active_idx_shock", "args": "active_args_shock",
	"prim": "shock", "prim_half": CellList.Half.LIVE,
	"back": true, "aux": "", "halo": true,
	"open_only": false, "inclusive": false,
	"thr": 0.0, "aux_thr": 0.0,
}]

var _cells: RefCounted = null
var _shock_args: RID = RID()

# Compute pipelines.
var _fert_pipe: RID = RID()
var _fungus_fert_pipe: RID = RID()
var _shock_pipe: RID = RID()

# Uniform sets, one per ping-pong parity.
var _fert_set: Array = [RID(), RID()]
var _fungus_fert_set: Array = [RID(), RID()]
var _shock_set: Array = [RID(), RID()]


func _setup(bufs: Dictionary, cc: int) -> void:
	_fert_pipe = _kernel(FERT_PATH)
	_fungus_fert_pipe = _kernel(FUNGUS_FERT_PATH)
	_shock_pipe = _kernel(SHOCK_PATH)

	_cells = CellList.new()
	_cells.rows = CELL_ROWS
	_cells.setup(_rd, bufs, cc)
	_shock_args = _cells.args_rid("shock")
	var shock_idx: RID = _single(bufs, "active_idx_shock")

	var solid_rid: RID = _single(bufs, "solid")
	var nbr_rid: RID = _single(bufs, "nbr")
	# Per-cell fertility scratch: written by ReactionsPass' decompose record, reduced by fungus_fert.
	var fungus_fert_rid: RID = _single(bufs, "fungus_fert")
	# Per-cell volume — fert and fungus_fert both include kernels3d/cellvol.glsli (binding 40).
	var cell_vol_rid: RID = _single(bufs, "cell_vol")

	var fert_pair: Array = _pair(bufs, "fert")
	var shock_pair: Array = _pair(bufs, "shock")

	for p in 2:
		var back: int = 1 - p

		_fert_set[p] = _uset(_fert_pipe, [
			[0, fert_pair[p]],       # FertIn  = live fertility
			[1, fert_pair[back]],    # FertOut = back fertility (fungus_fert then adds into THIS)
			[15, nbr_rid],
			[40, cell_vol_rid],
		])

		_fungus_fert_set[p] = _uset(_fungus_fert_pipe, [
			[0, fungus_fert_rid],    # FertCell = the per-cell scratch fungus just wrote
			[1, fert_pair[back]],    # Fert = fert's output (fert[back]), added into in place
			[2, solid_rid],          # Solid
			[15, nbr_rid],
			[40, cell_vol_rid],
		])

		_shock_set[p] = _uset(_shock_pipe, [
			[0, shock_pair[p]],      # ShockIn  = live shock
			[1, shock_pair[back]],   # ShockOut = back shock
			[2, solid_rid],          # Solid
			[4, shock_idx],          # ActiveIdx  — compacted cell list
			[5, _shock_args],        # ActiveArgs — [3] is the list length
			[15, nbr_rid],
		])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var precip: float = float(ctx.get("precip", 0.0))

	if _cells != null:
		_cells.dispatch(rd, cl, parity, ctx, cc, groups)
	# Order: fert -> fungus_fert -> shock.
	_run(rd, cl, _fert_pipe, _fert_set[parity], _pc_precip16(cc, precip), groups)
	_run(rd, cl, _fungus_fert_pipe, _fungus_fert_set[parity], _pc_cells(cc), groups)
	_run_indirect(rd, cl, _shock_pipe, _shock_set[parity], _pc_cells(cc), _shock_args)


## The compactor is a pass in its own right and owns its RIDs, so it is disposed before the base frees ours.
func dispose(rd: RenderingDevice) -> void:
	if _cells != null:
		_cells.dispose(rd)
		_cells = null
	_shock_args = RID()
	super.dispose(rd)


# --- helpers ------------------------------------------------------------------

## Records one single-pass CA into the open compute list, then a barrier so its writes are ordered ahead
## of the next kernel that reads them.
func _run(rd: RenderingDevice, cl: int, pipe: RID, uset: RID, pc: PackedByteArray, groups: int) -> void:
	rd.compute_list_bind_compute_pipeline(cl, pipe)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)


## Same, over the compacted active-cell list: group count comes from `args` slots 0-2, written this step.
func _run_indirect(rd: RenderingDevice, cl: int, pipe: RID, uset: RID, pc: PackedByteArray, args: RID) -> void:
	if not args.is_valid():
		return
	rd.compute_list_bind_compute_pipeline(cl, pipe)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch_indirect(cl, args, 0)
	rd.compute_list_add_barrier(cl)


## Push: {uint cell_count, pad, pad, float precip} — 16 bytes (fert).
func _pc_precip16(cc: int, precip: float) -> PackedByteArray:
	var b: PackedByteArray = PackedInt32Array([cc, 0, 0]).to_byte_array()
	b.append_array(PackedFloat32Array([precip]).to_byte_array())
	return b
