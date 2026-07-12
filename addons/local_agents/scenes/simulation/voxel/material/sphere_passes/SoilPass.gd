extends RefCounted

## Cubed-sphere GPU pass plugin: the SOIL WATER / WATER-TABLE CA (soil_sphere3d.glsl). Surface water soaks
## into the ground (up to a holding capacity) and the ground releases it back slowly as baseflow + saturation
## overflow — the reservoir that makes land water persist, rivers run perennial, and floods behave (dry soaks,
## saturated sheds). Wired to the SphereGPU driver via the plugin contract (setup once, dispatch each step).
##
## It runs AFTER AtmospherePass so it sees the settled + freshly-rained surface water. It modifies the settled
## water[back] IN PLACE (like the rain does) and ping-pongs the `soil` channel live→back. A 2-pass GATHER over
## the shared `send` scratch (self-zeroed in pass 0) keeps the vertical air↔ground exchange race-free.
##
## Per-parity binding → bufs map (see soil_sphere3d.glsl header for the authoritative layout):
##   0 Water = water[BACK] (settled surface water, read-modify-write) · 1 Solid · 2 Static · 3 Send scratch ·
##   4 SoilIn = soil[LIVE] · 5 SoilOut = soil[BACK] · 6 Regolith · 7 Temp = temp[BACK] (post-thermal, rw) · 15 Neigh
## Push constant: PackedInt32Array([cell_count, pass_id, 0, 0]).to_byte_array().

const SOIL_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/soil_sphere3d.glsl"

var _rd: RenderingDevice = null
var _shader: RID = RID()
var _pipe: RID = RID()
var _set: Array = [RID(), RID()]        # one uniform set per parity p in [0, 1]


func setup(rd: RenderingDevice, bufs: Dictionary, _cc: int) -> void:
	_rd = rd
	if _rd == null:
		push_error("SoilPass: null RenderingDevice")
		return
	var sf: RDShaderFile = load(SOIL_PATH)
	_shader = _rd.shader_create_from_spirv(sf.get_spirv())
	_pipe = _rd.compute_pipeline_create(_shader)

	var solid_rid: RID = bufs.get("solid", RID())
	var static_rid: RID = bufs.get("static", RID())
	var send_rid: RID = bufs.get("send", RID())
	var nbr_rid: RID = bufs.get("nbr", RID())
	var regolith_rid: RID = bufs.get("regolith", RID())
	var water_pair: Array = bufs.get("water", [RID(), RID()])
	var soil_pair: Array = bufs.get("soil", [RID(), RID()])
	var temp_pair: Array = bufs.get("temp", [RID(), RID()])

	for p in 2:
		var back: int = 1 - p
		_set[p] = _build_set(_shader, [
			[0, water_pair[back]],     # Water  = settled back water (read-modify-write)
			[1, solid_rid],            # Solid
			[2, static_rid],           # Static (sea reservoir — skipped)
			[3, send_rid],             # Send scratch
			[4, soil_pair[p]],         # SoilIn  = live soil (last step's output)
			[5, soil_pair[back]],      # SoilOut = back soil (this step's output)
			[6, regolith_rid],         # Regolith aquifer permeability mask
			[7, temp_pair[back]],      # Temp = POST-thermal temp (BACK, rw) — carry geothermal heat into springs
			[15, nbr_rid],             # Neigh table
		])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if _rd == null:
		return
	var uset: RID = _set[parity]
	var depth: int = int(ctx.get("depth", 20))
	var core_r: float = float(ctx.get("core_radius", 170.0))
	var cell_size: float = float(ctx.get("cell_size", 8.0))
	# PASS 0 — compute groundwater/infiltration/exfiltration transfers into `send`.
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	var pc0: PackedByteArray = _pc(cc, 0, depth, core_r, cell_size)
	rd.compute_list_set_push_constant(cl, pc0, pc0.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)
	# PASS 1 — apply.
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	var pc1: PackedByteArray = _pc(cc, 1, depth, core_r, cell_size)
	rd.compute_list_set_push_constant(cl, pc1, pc1.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)


func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for r in _set:
		if r is RID and r.is_valid():
			rd.free_rid(r)
	_set = [RID(), RID()]
	if _pipe.is_valid():
		rd.free_rid(_pipe)
	if _shader.is_valid():
		rd.free_rid(_shader)
	_pipe = RID()
	_shader = RID()


func _build_set(shader: RID, entries: Array) -> RID:
	var uniforms: Array = []
	for e in entries:
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(e[0])
		u.add_id(e[1])
		uniforms.append(u)
	return _rd.uniform_set_create(uniforms, shader, 0)


func _pc(cc: int, pass_id: int, depth: int, core_r: float, cell_size: float) -> PackedByteArray:
	# std430 push constant: 4x uint (cell_count, pass_id, depth, pad) then 2x float (core_radius, cell_size).
	var out: PackedByteArray = PackedInt32Array([cc, pass_id, depth, 0]).to_byte_array()
	out.append_array(PackedFloat32Array([core_r, cell_size]).to_byte_array())
	return out
