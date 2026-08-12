extends RefCounted


const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/erosion_pickup_sphere3d.glsl"

## Channels rc_shared.glsli reads that this kernel does not already bind, with the binding each arrives on.
## The half is the one settled where this pass sits in the dispatch order.
const RC_BACK_BINDS: Dictionary = {"lava": 20, "sediment": 30, "soil": 35, "moisture": 36}
const RC_LIVE_BINDS: Dictionary = {"dust": 32, "fungus": 37}
const RC_SINGLE_BINDS: Dictionary = {"snow": 19, "fuel": 21, "biomass": 22, "detritus": 23,
	"carbonate": 33, "silica": 34, "porosity": 38}

var _rd: RenderingDevice = null
var _shader: RID = RID()
var _pipe: RID = RID()
var _set: Array = [RID(), RID()]        # one uniform set per ping-pong parity


func setup(rd: RenderingDevice, bufs: Dictionary, _cc: int) -> void:
	_rd = rd
	if _rd == null:
		push_error("ErosionPickupPass: null RenderingDevice")
		return

	var sf: RDShaderFile = load(KERNEL_PATH)
	if sf == null:
		push_error("ErosionPickupPass: erosion_pickup_sphere3d.glsl failed to load (editor import scan needed?)")
		return
	_shader = _rd.shader_create_from_spirv(sf.get_spirv())
	if not _shader.is_valid():
		push_error("ErosionPickupPass: shader compile failed (run --import after editing the .glsl)")
		return
	_pipe = _rd.compute_pipeline_create(_shader)

	var solid_rid: RID = bufs.get("solid", RID())
	var rock_rid: RID = bufs.get("rock_fill", RID())
	var nbr_rid: RID = bufs.get("nbr", RID())
	var cvol_rid: RID = bufs.get("cell_vol", RID())
	var water_pair: Array = bufs.get("water", [RID(), RID()])
	var susp_pair: Array = bufs.get("susp", [RID(), RID()])
	var temp_pair: Array = bufs.get("temp", [RID(), RID()])

	for p in 2:
		var back: int = 1 - p
		# Read the SETTLED water (back half, matching ReactionsPass) and ADD the scour to the back susp that
		# ErosionTransportPass has just filled with the advected load.
		var entries: Array = [
			[0, water_pair[back]],   # Water = settled water (back)
			[1, solid_rid],          # Solid
			[2, temp_pair[back]],    # Temp = POST-thermal temp (BACK, rw)
			[3, rock_rid],           # RockFill (SINGLE, scoured in place)
			[4, susp_pair[back]],    # Susp = back susp (advected load; += scour, own-cell)
			[15, nbr_rid],           # Neigh table
			[40, cvol_rid],          # Per-cell volume
		]
		for name: String in RC_BACK_BINDS:
			var bp: Array = bufs.get(name, [RID(), RID()])
			entries.append([int(RC_BACK_BINDS[name]), bp[back]])
		for name: String in RC_LIVE_BINDS:
			var lp: Array = bufs.get(name, [RID(), RID()])
			entries.append([int(RC_LIVE_BINDS[name]), lp[p]])
		for name: String in RC_SINGLE_BINDS:
			entries.append([int(RC_SINGLE_BINDS[name]), bufs.get(name, RID())])
		_set[p] = _build_set(_shader, entries)


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if _rd == null or not _pipe.is_valid():
		return
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
	var pc: PackedByteArray = PackedInt32Array([cc, 0, 0, 0]).to_byte_array()
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)


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
