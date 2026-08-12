extends RefCounted

## Advects the suspended mineral load on the flowing water, carrying its enthalpy with it.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/erosion_transport_sphere3d.glsl"

## Channels rc_shared.glsli reads, with the binding each arrives on. The half is the one settled where this
## pass sits in the dispatch order: BACK for a producer that has already run this step, LIVE for one that
## has not.
const RC_BACK_BINDS: Dictionary = {"water": 7, "lava": 20, "sediment": 30, "soil": 35, "moisture": 36}
const RC_LIVE_BINDS: Dictionary = {"susp": 31, "dust": 32, "fungus": 37}
const RC_SINGLE_BINDS: Dictionary = {"rock_fill": 18, "snow": 19, "fuel": 21, "biomass": 22,
	"detritus": 23, "carbonate": 33, "silica": 34, "porosity": 38}

var _rd: RenderingDevice = null
var _shader: RID = RID()
var _pipe: RID = RID()
var _set: Array = [RID(), RID()]        # one uniform set per ping-pong parity
var _enabled: int = 1
## Enthalpy scratch, one slot per cell face, written by pass 0 and gathered by pass 1. A receiver cannot read
## its donor's temperature instead: pass 1 writes temp, so that read races the write.
var _send_h: RID = RID()


func setup(rd: RenderingDevice, bufs: Dictionary, cc: int) -> void:
	_rd = rd
	if _rd == null:
		push_error("ErosionTransportPass: null RenderingDevice")
		return
	if OS.has_environment("LA_EROSION_TRANSPORT"):
		_enabled = 1 if OS.get_environment("LA_EROSION_TRANSPORT") != "0" else 0

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
	var partner_rid: RID = bufs.get("link_partner", RID())
	var cvol_rid: RID = bufs.get("cell_vol", RID())
	var water_pair: Array = bufs.get("water", [RID(), RID()])
	var susp_pair: Array = bufs.get("susp", [RID(), RID()])
	var temp_pair: Array = bufs.get("temp", [RID(), RID()])
	var zeros: PackedByteArray = _zeros(cc * 6).to_byte_array()
	_send_h = _rd.storage_buffer_create(zeros.size(), zeros)

	for p in 2:
		var back: int = 1 - p
		var entries: Array = [
			[0, susp_pair[p]],       # SuspIn  = live susp
			[1, susp_pair[back]],    # SuspOut = back susp (fully written)
			[2, water_pair[p]],      # FlowHead = LIVE half: the pre-step head the water CA flowed on
			[3, solid_rid],          # Solid
			[4, _send_h],            # Enthalpy scratch, paired slot-for-slot with Send
			[5, send_rid],           # Shared outflow scratch (self-zeroed by pass 0)
			[6, temp_pair[back]],    # Temp = POST-thermal temp (BACK, rw)
			[15, nbr_rid], [17, partner_rid],           # Neigh table
			[40, cvol_rid],                             # Per-cell volume
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


func dispatch(rd: RenderingDevice, cl: int, parity: int, _ctx: Dictionary, cc: int, groups: int) -> void:
	if _rd == null or not _pipe.is_valid():
		return
	# PASS 0 — outflow into `send`; barrier; PASS 1 — inflow/apply into susp[back].
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
	var pc0: PackedByteArray = PackedInt32Array([cc, 0, _enabled, 0]).to_byte_array()
	rd.compute_list_set_push_constant(cl, pc0, pc0.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)

	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
	var pc1: PackedByteArray = PackedInt32Array([cc, 1, _enabled, 0]).to_byte_array()
	rd.compute_list_set_push_constant(cl, pc1, pc1.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)


## Free every RID this pass owns (uniform sets, pipeline, shader). Borrowed `bufs` entries are freed by the driver.
func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for s in _set:
		if s is RID and s.is_valid():
			rd.free_rid(s)
	_set = [RID(), RID()]
	for r: RID in [_pipe, _shader, _send_h]:
		if r.is_valid():
			rd.free_rid(r)
	_pipe = RID()
	_shader = RID()
	_send_h = RID()


static func _zeros(n: int) -> PackedFloat32Array:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	return a


func _build_set(shader: RID, entries: Array) -> RID:
	var uniforms: Array = []
	for e in entries:
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(e[0])
		u.add_id(e[1])
		uniforms.append(u)
	return _rd.uniform_set_create(uniforms, shader, 0)
