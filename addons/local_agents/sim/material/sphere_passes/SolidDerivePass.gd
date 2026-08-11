extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"


const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/solid_derive_sphere3d.glsl"

var _pipe: RID = RID()
var _set: Array = [RID(), RID()]     # one uniform set per ping-pong parity


func _setup(bufs: Dictionary, _cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)

	var rock_fill: RID = _single(bufs, "rock_fill")
	var solid: RID = _single(bufs, "solid")
	var sediment: Array = _pair(bufs, "sediment")
	var susp: Array = _pair(bufs, "susp")
	var dust: Array = _pair(bufs, "dust")
	var water: Array = _pair(bufs, "water")
	var moisture: Array = _pair(bufs, "moisture")
	var soil: Array = _pair(bufs, "soil")
	var snow: RID = _single(bufs, "snow")
	var regolith: RID = _single(bufs, "regolith")
	var grain: RID = _single(bufs, "grain")
	for p in 2:
		_set[p] = _uset(_pipe, [[0, rock_fill], [1, solid], [2, sediment[p]], [3, susp[p]], [4, dust[p]],
			[5, water[p]], [6, moisture[p]], [7, snow], [8, soil[p]], [9, regolith], [10, grain]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, _ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, cc)
	pc.encode_float(4, LAPhysical.GRAIN_D_LOWLAND_M)
	pc.encode_u32(8, 0)
	pc.encode_u32(12, 0)
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
