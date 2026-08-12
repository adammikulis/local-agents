extends RefCounted


const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/plate_advect_sphere3d.glsl"

var _rd: RenderingDevice = null
var _shader: RID = RID()
var _pipe: RID = RID()
var _set_rock: Array = [RID(), RID()]   # rock_fill is SINGLE, but pass 2 binds water (a pair) → one set per parity
var _set_sed: Array = [RID(), RID()]    # sediment is a ping-pong pair — one set per parity (live half)
var _enabled: bool = true


func setup(rd: RenderingDevice, bufs: Dictionary, _cc: int) -> void:
	_rd = rd
	if _rd == null:
		push_error("PlateAdvectPass: null RenderingDevice")
		return
	_enabled = OS.get_environment("LA_NO_PLATE_ADVECT") == ""

	var sf: RDShaderFile = load(KERNEL_PATH)
	if sf == null:
		push_error("PlateAdvectPass: plate_advect_sphere3d.glsl failed to load (editor import scan needed?)")
		return
	_shader = _rd.shader_create_from_spirv(sf.get_spirv())
	if not _shader.is_valid():
		push_error("PlateAdvectPass: shader compile failed (run --import after editing the .glsl)")
		return
	_pipe = _rd.compute_pipeline_create(_shader)

	var send_rid: RID = bufs.get("send", RID())
	var radial_rid: RID = bufs.get("radial", RID())
	var pos_rid: RID = bufs.get("pos", RID())
	var nbr_rid: RID = bufs.get("nbr", RID())
	var shell_rid: RID = bufs.get("shell", RID())
	var cvol_rid: RID = bufs.get("cell_vol", RID())
	var partner_rid: RID = bufs.get("link_partner", RID())
	var plates_rid: RID = bufs.get("plates", RID())
	var rock_rid: RID = bufs.get("rock_fill", RID())
	var sed_pair: Array = bufs.get("sediment", [RID(), RID()])
	if not plates_rid.is_valid() or not rock_rid.is_valid():
		push_error("PlateAdvectPass: driver did not provide the plates/rock_fill buffers")
		return

	var water_pair: Array = bufs.get("water", [RID(), RID()])
	for p in 2:
		_set_rock[p] = _build_set([
			[0, rock_rid], [1, send_rid], [2, radial_rid], [3, pos_rid], [4, nbr_rid], [17, partner_rid],
			[39, shell_rid], [40, cvol_rid], [5, plates_rid],
			[6, water_pair[p]], [7, rock_rid]])
		_set_sed[p] = _build_set([
			[0, sed_pair[p]], [1, send_rid], [2, radial_rid], [3, pos_rid], [4, nbr_rid], [17, partner_rid],
			[39, shell_rid], [40, cvol_rid], [5, plates_rid],
			[6, water_pair[p]], [7, rock_rid]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if _rd == null or not _pipe.is_valid():
		return
	var n_plates: int = int(ctx.get("n_plates", 0)) if _enabled else 0
	# BEDROCK first, then its loose cover. Both are two dispatches (outflow, then gather) over the shared
	# `send` scratch, so the four are strictly ordered with a barrier between each.
	var rock_set: RID = _set_rock[parity]
	_carry(rd, cl, rock_set, ctx, cc, groups, n_plates)
	var sed_set: RID = _set_sed[parity]
	if sed_set.is_valid():
		_carry(rd, cl, sed_set, ctx, cc, groups, n_plates)
	# ...and then ONE displacement pass, after both mineral channels have settled, so it sees the rock where it
	# now is. Skipped entirely when the crust is not moving — with no advection nothing newly closes over water,
	if n_plates > 0 and rock_set.is_valid():
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, rock_set, 0)
		rd.compute_list_set_push_constant(cl, _push(ctx, cc, 2, n_plates), 28)
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)


func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for s in _set_rock:
		if s is RID and s.is_valid():
			rd.free_rid(s)
	_set_rock = [RID(), RID()]
	for s in _set_sed:
		if s is RID and s.is_valid():
			rd.free_rid(s)
	_set_sed = [RID(), RID()]
	if _pipe.is_valid():
		rd.free_rid(_pipe)
		_pipe = RID()
	if _shader.is_valid():
		rd.free_rid(_shader)
		_shader = RID()


# --- helpers ------------------------------------------------------------------

## One channel's transport: PASS 0 writes the outflow into `send`; barrier; PASS 1 gathers and applies in place.
func _carry(rd: RenderingDevice, cl: int, uset: RID, ctx: Dictionary, cc: int, groups: int, n_plates: int) -> void:
	if not uset.is_valid():
		return
	for pass_id in 2:
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, uset, 0)
		rd.compute_list_set_push_constant(cl, _push(ctx, cc, pass_id, n_plates), 28)
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)


func _push(ctx: Dictionary, cc: int, pass_id: int, n_plates: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(28)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, pass_id)
	pc.encode_u32(8, maxi(n_plates, 0))
	pc.encode_u32(12, maxi(int(ctx.get("depth", 1)), 1))
	pc.encode_float(16, float(ctx.get("dt", 0.1)))
	pc.encode_float(20, float(ctx.get("lat_size", 1.0)))
	pc.encode_float(24, float(ctx.get("max_mass", 1.0)))
	return pc


func _build_set(entries: Array) -> RID:
	var uniforms: Array = []
	for e in entries:
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(e[0])
		u.add_id(e[1])
		uniforms.append(u)
	return _rd.uniform_set_create(uniforms, _shader, 0)
