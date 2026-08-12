extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"


const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/solid_derive_sphere3d.glsl"

var _pipe: RID = RID()
var _set: Array = [RID(), RID()]     # one uniform set per ping-pong parity


func _setup(bufs: Dictionary, _cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)

	var solid: RID = _single(bufs, "solid")
	var cement: RID = _single(bufs, "cement")
	var melt: RID = _single(bufs, "silicate_melt")
	var pressure: RID = _single(bufs, "pressure")
	var regolith: RID = _single(bufs, "regolith")
	var grain: RID = _single(bufs, "grain")
	for p in 2:
		_set[p] = _uset(_pipe, [[0, _half(bufs, "silicate", p, false)], [1, solid], [2, cement],
			[3, melt], [4, pressure], [5, _half(bufs, "h2o", p, false)],
			[9, regolith], [10, grain]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, _ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_float(4, LAPhysical.GRAIN_D_LOWLAND_M)
	pc.encode_float(8, LAPhysical.LITHIFICATION_RATE_PER_PA)
	pc.encode_float(12, LAPhysical.LITHIFICATION_PRESSURE_PA)
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
