extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"


const SOIL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl"

var _pipe: RID = RID()
var _set: Array = [RID(), RID()]        # one uniform set per parity p in [0, 1]


func _setup(bufs: Dictionary, _cc: int) -> void:
	_pipe = _kernel(SOIL_PATH)

	var b: Dictionary = _rids(bufs,
		["solid", "send", "heat_send", "nbr", "regolith", "grain", "soil_dbg", "porosity"],
		["water", "soil", "temp"])

	for p in 2:
		var back: int = 1 - p
		_set[p] = _uset(_pipe, [
			[0, b["water"][back]],     # Water  = settled back water (read-modify-write)
			[1, b["solid"]],
			[3, b["send"]],            # Send scratch
			[4, b["soil"][p]],         # SoilIn  = live soil (last step's output)
			[5, b["soil"][back]],      # SoilOut = back soil (this step's output)
			[6, b["regolith"]],        # Regolith aquifer permeability mask
			[7, b["temp"][back]],      # Temp = POST-thermal temp (BACK, rw) — carry geothermal heat into springs
			[8, b["grain"]],           # Grain diameter (m) — Kozeny-Carman input, with the Athy porosity profile
			[9, b["soil_dbg"]],        # SoilDbg — per-leg budget probe (LAMaterialSphereGPU3D.SOIL_DBG_SLOTS)
			[10, b["heat_send"]],      # HeatSend scratch — send * donor temp, gathered by the receiver
			[11, b["porosity"]],       # Porosity — phi, published for every other consumer of rock_fill
			[15, b["nbr"]],            # Neigh table
		])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable():
		return
	var uset: RID = _set[parity]
	var depth: int = _ctx_depth(ctx)
	var core_r: float = _ctx_core_radius(ctx)
	var cell_size: float = _ctx_cell_size(ctx)
	# PASS 0 — compute groundwater/infiltration/exfiltration transfers into `send`; PASS 1 — apply.
	for pass_id in 2:
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, uset, 0)
		var pc: PackedByteArray = _pc(cc, pass_id, depth, core_r, cell_size)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)


## std430 push constant: 4x uint (cell_count, pass_id, depth, pad), then 4x float (core_radius, cell_size,
## regolith shell thickness in metres, real seconds per field step).
func _pc(cc: int, pass_id: int, depth: int, core_r: float, cell_size: float) -> PackedByteArray:
	var out: PackedByteArray = PackedInt32Array([cc, pass_id, depth, 0]).to_byte_array()
	out.append_array(PackedFloat32Array([core_r, cell_size,
		LAMaterialFieldRegolith3D.shell_metres(),
		LAMaterialFieldSphereStep3D.real_seconds_per_step()]).to_byte_array())
	return out
