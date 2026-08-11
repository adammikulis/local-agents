extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Advection of the waterborne suspended load: outflow into the shared `send` scratch, then a conservative
## gather back into susp.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/erosion_transport_sphere3d.glsl"

var _pipe: RID = RID()
var _set: Array = [RID(), RID()]        # one uniform set per ping-pong parity


func _setup(bufs: Dictionary, _cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)

	var solid_rid: RID = _single(bufs, "solid")
	var send_rid: RID = _single(bufs, "send")
	var nbr_rid: RID = _single(bufs, "nbr")
	var omega_rid: RID = _single(bufs, "solid_angle")
	var water_pair: Array = _pair(bufs, "water")
	var susp_pair: Array = _pair(bufs, "susp")

	for p in 2:
		var back: int = 1 - p
		_set[p] = _uset(_pipe, [
			[0, susp_pair[p]],       # SuspIn  = live susp
			[1, susp_pair[back]],    # SuspOut = back susp (fully written)
			[2, water_pair[p]],      # Water   = LIVE half: the pre-step head the water CA flowed on
			[3, solid_rid],          # Solid
			[5, send_rid],           # Shared outflow scratch (self-zeroed by pass 0)
			[15, nbr_rid],           # Neigh table
			[17, omega_rid],         # solid angle per column — cell volume, for the conservative gather
		])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var depth: int = _ctx_depth(ctx)
	var core_radius: float = _ctx_core_radius(ctx)
	var cell_size: float = _ctx_cell_size(ctx)
	# PASS 0 — outflow into `send`; barrier; PASS 1 — inflow/apply into susp[back].
	for pass_id in 2:
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
		var pc: PackedByteArray = _pc(cc, pass_id, depth, core_radius, cell_size)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)


## { cell_count, pass_id, depth, pad, core_radius, cell_size } — 24 bytes.
func _pc(cc: int, pass_id: int, depth: int, core_radius: float, cell_size: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(24)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, pass_id)
	pc.encode_u32(8, depth)
	pc.encode_u32(12, 0)
	pc.encode_float(16, core_radius)
	pc.encode_float(20, cell_size)
	return pc
