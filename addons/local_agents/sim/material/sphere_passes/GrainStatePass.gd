extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## WHERE THE LOOSE MINERAL GRAINS ARE — suspended in water, suspended in air, or on the bed. Reads the
## velocity field, the grain diameter, the melt share and `cement`; writes three derived shares that sum to
## the cell's loose share. It writes no channel and mutates no state.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/grain_state.glsl"

const OUT_BUFFERS: PackedStringArray = ["silicate_susp_water", "silicate_susp_air", "silicate_bed"]

var _pipe: RID = RID()
var _set: Array = [RID(), RID()]     # one uniform set per ping-pong parity


func _setup(bufs: Dictionary, _cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	if not _pipe.is_valid():
		return
	var missing: PackedStringArray = PackedStringArray()
	for name: String in ["silicate", "cement", "nbr", "solid", "gravity", "vel_x", "vel_y", "vel_z",
			"grain", "h2o", "h2o_solid", "h2o_liquid", "silicate_melt"]:
		if not bufs.has(name):
			missing.append(name)
	for name: String in OUT_BUFFERS:
		if not bufs.has(name):
			missing.append(name)
	if not missing.is_empty():
		push_error("GrainStatePass: no buffer for %s, so no grain would know whether it is carried."
			% String(", ").join(missing))
		return
	for p in 2:
		_set[p] = _uset(_pipe, [
			[0, _half(bufs, "silicate", p, false)],
			[1, _single(bufs, "cement")],
			[2, _single(bufs, "nbr")],
			[3, _single(bufs, "solid")],
			[4, _single(bufs, "gravity")],
			[5, _single(bufs, "vel_x")], [6, _single(bufs, "vel_y")], [7, _single(bufs, "vel_z")],
			[8, _single(bufs, "grain")],
			[9, _half(bufs, "h2o", p, false)],
			[10, _single(bufs, "h2o_solid")],
			[11, _single(bufs, "h2o_liquid")],
			[12, _single(bufs, "silicate_melt")],
			[13, _single(bufs, "silicate_susp_water")],
			[14, _single(bufs, "silicate_susp_air")],
			[15, _single(bufs, "silicate_bed")],
		])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable() or not _set[parity].is_valid():
		return
	var rho_grain: float = float(LASubstances.table().get("silicate", {}).get("density", 0.0))
	if rho_grain <= 0.0:
		push_error("GrainStatePass: LASubstances gives silicate no density, so no grain has a fall speed.")
		return
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_float(4, _ctx_cell_size(ctx))
	pc.encode_float(8, LAPhysical.GRAIN_D_UPLAND_M)
	pc.encode_float(12, rho_grain)
	pc.encode_float(16, LAPhysical.WATER_DENSITY_KG_M3)
	pc.encode_float(20, LAPhysical.WATER_DYNAMIC_VISCOSITY_PA_S)
	pc.encode_float(24, LAPhysical.AIR_DENSITY_KG_M3)
	pc.encode_float(28, LAPhysical.AIR_DYNAMIC_VISCOSITY_PA_S)
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
