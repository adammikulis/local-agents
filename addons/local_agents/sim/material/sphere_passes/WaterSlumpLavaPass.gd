extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## Gravity-driven mass movement for every flowing material, through one kernel.
## Two passes per material (outflow, then gather) sharing the driver's `send` scratch.

const FLOW_PATH: String = "res://addons/local_agents/sim/material/kernels3d/gravity_flow_sphere3d.glsl"

## One row per flowing material. `repose` is LAPhysical.REPOSE_TAN_DRY_GRANULAR for granular material and 0
## for a fluid, which levels out freely. The flow caps are model parameters of this grid and step.
const MATERIALS: Array = [
	{"channel": "water", "max_flow": 1.0, "lateral": 0.5, "repose": 0.0},
	{"channel": "sediment", "max_flow": 0.5, "lateral": 0.25,
		"repose": LAPhysical.REPOSE_TAN_DRY_GRANULAR},
	{"channel": "lava", "max_flow": 0.25, "lateral": 0.25, "repose": 0.0},
]
const MIN_FLOW: float = 0.01
const MIN_MASS: float = 0.0001

var _flow_pipe: RID = RID()
## _sets[material_index][parity]
var _sets: Array = []


func _setup(bufs: Dictionary, _cc: int) -> void:
	_flow_pipe = _kernel(FLOW_PATH)

	var send_rid: RID = _single(bufs, "send")
	var solid_rid: RID = _single(bufs, "solid")
	var nbr_rid: RID = _single(bufs, "nbr")
	var larc_rid: RID = _single(bufs, "link_arc")
	var omega_rid: RID = _single(bufs, "solid_angle")
	var temp_pair: Array = _pair(bufs, "temp")

	_sets = []
	for _m in MATERIALS.size():
		_sets.append([RID(), RID()])
	for p in 2:
		var back: int = 1 - p
		for mi in MATERIALS.size():
			var pair: Array = _pair(bufs, String(MATERIALS[mi]["channel"]))
			_sets[mi][p] = _uset(_flow_pipe, [
				[0, pair[p]], [1, pair[back]], [2, send_rid], [3, solid_rid],
				[5, temp_pair[p]], [15, nbr_rid], [16, larc_rid], [17, omega_rid],
			])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var depth: int = _ctx_depth(ctx)
	var core_radius: float = _ctx_core_radius(ctx)
	var cell_size: float = _ctx_cell_size(ctx)
	for mi in MATERIALS.size():
		_two_pass(rd, cl, _sets[mi][parity], cc, groups, MATERIALS[mi], depth, core_radius, cell_size)


# --- helpers ------------------------------------------------------------------

func _two_pass(rd: RenderingDevice, cl: int, uset: RID, cc: int, groups: int, mat: Dictionary,
		depth: int, core_radius: float, cell_size: float) -> void:
	for pass_id in 2:
		rd.compute_list_bind_compute_pipeline(cl, _flow_pipe)
		rd.compute_list_bind_uniform_set(cl, uset, 0)
		var pc: PackedByteArray = _pc(cc, pass_id, mat, depth, core_radius, cell_size)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)


## { cell_count, pass_id, depth, core_radius, cell_size, max_flow, min_flow, min_mass, lateral, repose }
func _pc(cc: int, pass_id: int, mat: Dictionary, depth: int, core_radius: float,
		cell_size: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(40)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, pass_id)
	pc.encode_u32(8, depth)
	pc.encode_float(12, core_radius)
	pc.encode_float(16, cell_size)
	pc.encode_float(20, float(mat["max_flow"]))
	pc.encode_float(24, MIN_FLOW)
	pc.encode_float(28, MIN_MASS)
	pc.encode_float(32, float(mat["lateral"]))
	pc.encode_float(36, float(mat["repose"]))
	return pc
