extends RefCounted


const SOIL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/soil_sphere3d.glsl"

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
	var spirv: RDShaderSPIRV = sf.get_spirv()
	# FAIL LOUD ON A KERNEL THAT DID NOT COMPILE. Godot's own message for this is "Can't create a shader from
	# an errored bytecode", which says nothing about WHICH kernel or WHY, and the driver's WIP-tolerant pass
	# loader then keeps the pass in the list with a null pipeline — so the aquifer silently stops running and
	var err: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not err.is_empty():
		push_error("SoilPass: " + SOIL_PATH.get_file() + " failed to compile — the aquifer will not run.\n" + err)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipe = _rd.compute_pipeline_create(_shader)

	var solid_rid: RID = bufs.get("solid", RID())
	var send_rid: RID = bufs.get("send", RID())
	var nbr_rid: RID = bufs.get("nbr", RID())
	var shell_rid: RID = bufs.get("shell", RID())
	var cvol_rid: RID = bufs.get("cell_vol", RID())
	var partner_rid: RID = bufs.get("link_partner", RID())
	var regolith_rid: RID = bufs.get("regolith", RID())
	var grain_rid: RID = bufs.get("grain", RID())
	var water_pair: Array = bufs.get("water", [RID(), RID()])
	var soil_pair: Array = bufs.get("soil", [RID(), RID()])
	var temp_pair: Array = bufs.get("temp", [RID(), RID()])
	var dbg_rid: RID = bufs.get("soil_dbg", RID())

	for p in 2:
		var back: int = 1 - p
		_set[p] = _build_set(_shader, [
			[0, water_pair[back]],     # Water  = settled back water (read-modify-write)
			[1, solid_rid],            # Solid
			[3, send_rid],             # Send scratch
			[4, soil_pair[p]],         # SoilIn  = live soil (last step's output)
			[5, soil_pair[back]],      # SoilOut = back soil (this step's output)
			[6, regolith_rid],         # Regolith aquifer permeability mask
			[7, temp_pair[back]],      # Temp = POST-thermal temp (BACK, rw) — carry geothermal heat into springs
			[8, grain_rid],            # Grain diameter (m) — Kozeny-Carman input, with the Athy porosity profile
			[9, dbg_rid],              # SoilDbg — per-leg budget probe (LAMaterialSphereGPU3D.SOIL_DBG_SLOTS)
			[11, bufs["porosity"]],    # Porosity — phi, published for every other consumer of rock_fill
			[15, nbr_rid], [17, partner_rid], [39, shell_rid],   # Neigh + shell tables
			[40, cvol_rid],            # Per-cell volume (kernels3d/cellvol.glsli)
		])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if _rd == null or not _pipe.is_valid():
		return                                  # no device, or the kernel failed to compile (setup push_error'd)
	var uset: RID = _set[parity]
	var depth: int = int(ctx.get("depth", 20))
	var lat_size: float = float(ctx.get("lat_size", 8.0))
	# PASS 0 — compute groundwater/infiltration/exfiltration transfers into `send`.
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	var pc0: PackedByteArray = _pc(cc, 0, depth, lat_size)
	rd.compute_list_set_push_constant(cl, pc0, pc0.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)
	# PASS 1 — apply.
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	var pc1: PackedByteArray = _pc(cc, 1, depth, lat_size)
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


## std430: 4x uint (cell_count, pass_id, depth, pad) then 3x float (lat_size, shell_m, step_s).
func _pc(cc: int, pass_id: int, depth: int, lat_size: float) -> PackedByteArray:
	var out: PackedByteArray = PackedInt32Array([cc, pass_id, depth, 0]).to_byte_array()
	out.append_array(PackedFloat32Array([lat_size,
		LAMaterialFieldRegolith3D.shell_metres(),
		LAMaterialFieldSphereStep3D.real_seconds_per_step()]).to_byte_array())
	return out
