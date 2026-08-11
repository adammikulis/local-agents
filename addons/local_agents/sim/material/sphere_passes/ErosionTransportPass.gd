extends RefCounted

## all: erosion pickup scoured bedrock into `susp` and credited it to the scouring cell, and M3 SETTLE put it

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/erosion_transport_sphere3d.glsl"

var _rd: RenderingDevice = null
var _shader: RID = RID()
var _pipe: RID = RID()
var _set: Array = [RID(), RID()]        # one uniform set per ping-pong parity


func setup(rd: RenderingDevice, bufs: Dictionary, _cc: int) -> void:
	_rd = rd
	if _rd == null:
		push_error("ErosionTransportPass: null RenderingDevice")
		return

	var sf: RDShaderFile = load(KERNEL_PATH)
	if sf == null:
		push_error("ErosionTransportPass: erosion_transport_sphere3d.glsl failed to load (editor import scan needed?)")
		return
	_shader = _rd.shader_create_from_spirv(sf.get_spirv())
	if not _shader.is_valid():
		push_error("ErosionTransportPass: shader compile failed (run --import after editing the .glsl)")
		return
	_pipe = _rd.compute_pipeline_create(_shader)

	var solid_rid: RID = bufs.get("solid", RID())
	var send_rid: RID = bufs.get("send", RID())
	var nbr_rid: RID = bufs.get("nbr", RID())
	var omega_rid: RID = bufs.get("solid_angle", RID())
	var water_pair: Array = bufs.get("water", [RID(), RID()])
	var susp_pair: Array = bufs.get("susp", [RID(), RID()])

	for p in 2:
		var back: int = 1 - p
		_set[p] = _build_set(_shader, [
			[0, susp_pair[p]],       # SuspIn  = live susp
			[1, susp_pair[back]],    # SuspOut = back susp (fully written)
			[2, water_pair[p]],      # Water   = LIVE half: the pre-step head the water CA actually flowed on
			                         # (nothing after the CA writes this half; see the kernel header)
			[3, solid_rid],          # Solid
			[5, send_rid],           # Shared outflow scratch (self-zeroed by pass 0)
			[15, nbr_rid],           # Neigh table
			[17, omega_rid],         # solid angle per column — cell volume, for the conservative gather
		])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if _rd == null or not _pipe.is_valid():
		return
	var depth: int = maxi(int(ctx.get("depth", 1)), 1)
	var core_radius: float = float(ctx.get("core_radius", 0.0))
	var cell_size: float = float(ctx.get("cell_size", 1.0))
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


## Free every RID this pass owns (uniform sets, pipeline, shader). Borrowed `bufs` entries are freed by the driver.
func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for s in _set:
		if s is RID and s.is_valid():
			rd.free_rid(s)
	_set = [RID(), RID()]
	if _pipe.is_valid():
		rd.free_rid(_pipe)
		_pipe = RID()
	if _shader.is_valid():
		rd.free_rid(_shader)
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
