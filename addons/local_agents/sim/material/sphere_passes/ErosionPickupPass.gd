extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"


const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/erosion_pickup_sphere3d.glsl"

var _pipe: RID = RID()
var _set: Array = [RID(), RID()]        # one uniform set per ping-pong parity


func _setup(bufs: Dictionary, _cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)

	var solid_rid: RID = _single(bufs, "solid")
	var rock_rid: RID = _single(bufs, "rock_fill")
	var nbr_rid: RID = _single(bufs, "nbr")
	var water_pair: Array = _pair(bufs, "water")
	var susp_pair: Array = _pair(bufs, "susp")

	for p in 2:
		var back: int = 1 - p
		# Read the SETTLED water (back half, matching ReactionsPass) and ADD the scour to the back susp that
		# ErosionTransportPass has just filled with the advected load.
		_set[p] = _uset(_pipe, [
			[0, water_pair[back]],   # WaterIn = settled water (back)
			[1, solid_rid],          # Solid
			[3, rock_rid],           # RockFill (SINGLE, scoured in place)
			[4, susp_pair[back]],    # Susp = back susp (advected load; += scour, own-cell)
			[15, nbr_rid],           # Neigh table
		])


func dispatch(rd: RenderingDevice, cl: int, parity: int, _ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
	var pc: PackedByteArray = _pc_cells(cc)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
