extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Non-inductive charge separation, then the breakdown column scan and the return stroke.

const SEPARATE_PATH: String = "res://addons/local_agents/sim/material/kernels3d/charge_separate.glsl"
const BREAKDOWN_PATH: String = "res://addons/local_agents/sim/material/kernels3d/charge_breakdown_sphere3d.glsl"

const PASS_RESET: int = 0
const PASS_SCAN: int = 1
const PASS_NEUTRALISE: int = 2

var _sep_pipe: RID = RID()
var _pipe: RID = RID()
var _sep_set: Array = [RID(), RID()]
var _sets: Array = [RID(), RID()]


func _setup(bufs: Dictionary, _cc: int) -> void:
	_sep_pipe = _kernel(SEPARATE_PATH)
	_pipe = _kernel(BREAKDOWN_PATH)
	for k in ["strike_idx", "strike_args", "sigma_col", "gravity"]:
		if not bufs.has(k):
			push_error("ChargeBreakdownPass: no \"%s\" buffer, so no flash can initiate." % k)
			return
	# Separation charges the two hydrometeor phases by how hard the air is lifting them, so it needs the
	# component of velocity along -g. Nothing derives it yet, and +Y is not up on this grid.
	var lifted: bool = bufs.has("vel_up")
	if not lifted:
		push_error("ChargeBreakdownPass: no \"vel_up\" buffer, so no charge is ever separated.")

	for p in 2:
<<<<<<< HEAD
		if lifted:
			_sep_set[p] = _uset(_sep_pipe, [
				[0, _single(bufs, "charge")],
				[1, _half(bufs, "temp", p, false)],
				[2, _half(bufs, "moisture", p, false)],
				[3, _single(bufs, "nbr")],
				[4, _single(bufs, "gravity")],
				[5, _single(bufs, "vel_up")]])
		_sets[p] = _uset(_pipe, [
			[0, _single(bufs, "charge")], [1, _single(bufs, "solid")],
			[2, _half(bufs, "temp", p, false)], [3, _single(bufs, "pos")],
			[4, _single(bufs, "gravity")],
			[7, _single(bufs, "pressure")], [43, _single(bufs, "discharge")],
			[44, _single(bufs, "strike_idx")], [45, _single(bufs, "strike_args")],
			[46, _single(bufs, "sigma_col")],
			[5, _half(bufs, "water", p, true)], [6, _single(bufs, "rock_fill")],
			[20, _half(bufs, "lava", p, true)], [21, _single(bufs, "fuel")],
			[22, _single(bufs, "biomass")], [23, _single(bufs, "detritus")],
			[30, _half(bufs, "sediment", p, false)], [31, _half(bufs, "susp", p, false)],
			[32, _half(bufs, "dust", p, false)], [33, _single(bufs, "carbonate")],
			[34, _single(bufs, "silica")], [35, _half(bufs, "soil", p, false)],
			[36, _half(bufs, "moisture", p, false)], [37, _half(bufs, "fungus", p, false)],
			[38, _single(bufs, "porosity")]])
=======
		var back: int = 1 - p
		_sets[p] = _build_set(rd, _shader, [
			[0, bufs["charge"]], [1, bufs["solid"]], [2, bufs["temp"][p]], [3, bufs["pos"]],
			[7, bufs["pressure"]], [43, bufs["discharge"]],
			[44, bufs["strike_idx"]], [45, bufs["strike_args"]], [46, bufs["sigma_col"]],
			[4, bufs["snow"]], [5, bufs["water"][back]], [6, bufs["rock_fill"]],
			[20, bufs["lava"][back]], [21, bufs["fuel"]], [22, bufs["biomass"]],
			[23, bufs["detritus"]], [30, bufs["sediment"][p]], [31, bufs["susp"][p]],
			[32, bufs["dust"][p]], [33, bufs["carbonate"]], [34, bufs["silica"]],
			[35, bufs["soil"][p]], [36, bufs["moisture"][p]], [37, bufs["fungus"]],
			[38, bufs["porosity"]], [39, bufs["shell"]]])
>>>>>>> worktree-agent-ae18d3bf4ba96c0e0


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var cell_m: float = _ctx_cell_size(ctx)
	var dt_s: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()

	# SEPARATION — rebounding graupel-ice collisions charge the two phases oppositely; they fall apart.
	if _sep_set[parity].is_valid():
		rd.compute_list_bind_compute_pipeline(cl, _sep_pipe)
		rd.compute_list_bind_uniform_set(cl, _sep_set[parity], 0)
		var pc_sep: PackedByteArray = _pc_separate(cc, dt_s)
		rd.compute_list_set_push_constant(cl, pc_sep, pc_sep.size())
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)

	var depth: int = _ctx_depth(ctx)
	var columns: int = cc / depth
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _sets[parity], 0)
	_record(rd, cl, _pc(cc, depth, PASS_RESET, cell_m), 1)
	_record(rd, cl, _pc(cc, depth, PASS_SCAN, cell_m), int(ceil(float(columns) / 64.0)))
	_record(rd, cl, _pc(cc, depth, PASS_NEUTRALISE, cell_m), groups)


# --- helpers ---------------------------------------------------------------------------------------------

func _record(rd: RenderingDevice, cl: int, pc: PackedByteArray, groups: int) -> void:
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)


# Params { uint cell_count; uint depth; uint pass_id; float cell_m; float radius_model; } — 20 bytes.
func _pc(cc: int, depth: int, pass_id: int, cell_m: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(20)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, depth)
	pc.encode_u32(8, pass_id)
	pc.encode_float(12, cell_m)
	pc.encode_float(16, LAPhysical.LIGHTNING_NEUTRALISED_RADIUS_M)
	return pc


# Params { uint cell_count; float dt_s; float rate_c_m3_s; float zone_warm_c; float zone_cold_c;
#          float updraft_ref; float lwc_ref; uint pad0; } — 32 bytes.
func _pc_separate(cc: int, dt_s: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_float(4, dt_s)
	pc.encode_float(8, LAPhysical.NIC_CHARGE_RATE_C_M3_S)
	pc.encode_float(12, LAPhysical.CHARGE_ZONE_WARM_C)
	pc.encode_float(16, LAPhysical.CHARGE_ZONE_COLD_C)
	pc.encode_float(20, LAPhysical.CONVECTIVE_UPDRAFT_M_S)
	pc.encode_float(24, LAPhysical.CHARGING_LWC_KG_M3)
	pc.encode_u32(28, 0)
	return pc
