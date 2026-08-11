extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"


const SOIL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl"

var _pipe: RID = RID()
var _set: Array = [RID(), RID()]        # one uniform set per parity p in [0, 1]


func _setup(bufs: Dictionary, _cc: int) -> void:
	_pipe = _kernel(SOIL_PATH)

	var solid_rid: RID = _single(bufs, "solid")
	var send_rid: RID = _single(bufs, "send")
	var nbr_rid: RID = _single(bufs, "nbr")
	var regolith_rid: RID = _single(bufs, "regolith")
	var grain_rid: RID = _single(bufs, "grain")
	var water_pair: Array = _pair(bufs, "water")
	var soil_pair: Array = _pair(bufs, "soil")
	var temp_pair: Array = _pair(bufs, "temp")
	var dbg_rid: RID = _single(bufs, "soil_dbg")

	for p in 2:
		var back: int = 1 - p
		_set[p] = _uset(_pipe, [
			[0, water_pair[back]],     # Water  = settled back water (read-modify-write)
			[1, solid_rid],            # Solid
			[3, send_rid],             # Send scratch
			[4, soil_pair[p]],         # SoilIn  = live soil (last step's output)
			[5, soil_pair[back]],      # SoilOut = back soil (this step's output)
			[6, regolith_rid],         # Regolith aquifer permeability mask
			[7, temp_pair[back]],      # Temp = POST-thermal temp (BACK, rw) — carry geothermal heat into springs
			[8, grain_rid],            # Grain diameter (m) — Kozeny-Carman input, with the Athy porosity profile
			[9, dbg_rid],              # SoilDbg — per-leg budget probe (LAMaterialSphereGPU3D.SOIL_DBG_SLOTS)
			[11, _single(bufs, "porosity")],   # Porosity — phi, published for every other consumer of rock_fill
			[15, nbr_rid],             # Neigh table
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
