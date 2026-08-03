extends RefCounted

## Cubed-sphere GPU pass plugin: EROSION TRANSPORT — suspended sediment rides the water downstream.
##
## Wires the ONE kernel erosion_transport_sphere3d.glsl into the SphereGPU driver via the plugin contract
## (setup() once, dispatch() each step). Before this pass existed the mineral cycle had no advection leg at
## all: erosion pickup scoured bedrock into `susp` and credited it to the scouring cell, and M3 SETTLE put it
## straight back down as `sediment` in that same cell. A river scoured its bed and refilled it in the same
## step, so deltas, beaches, floodplains and canyons were not unproven — they were impossible.
##
## PLACEMENT (MaterialSphereGPU3D.PASS_SCRIPTS): immediately BEFORE ErosionPickupPass, which is itself
## immediately before ReactionsPass. That order is forced by the ping-pong, and gives each of the three one
## unambiguous job on the back half of `susp`:
##   1. THIS pass reads susp[live] and FULLY writes susp[back] — every cell, moved.
##   2. ErosionPickupPass adds this step's fresh scour to susp[back] IN PLACE (own-cell only, so a
##      read-modify-write on one buffer is race-free).
##   3. ReactionsPass reads susp[back] for M3 SETTLE.
## Transport therefore moves LAST step's load and pickup adds THIS step's, which is the right way round: a
## grain has to be in the water before the water can carry it.
##
## SHARED `send` SCRATCH. This is a two-pass gather and uses the driver's single cc*6 outflow scratch
## (bufs["send"]), exactly as WaterSlumpLavaPass and SoilPass do. That is safe because pass 0 unconditionally
## self-zeroes all six of its own slots before any early return, and because the three consumers are strictly
## ordered within one step (WaterSlumpLava -> Soil -> here) with no reader in between. If a future pass is
## inserted between SoilPass and this one and also uses `send`, it must follow the same self-zeroing rule.
##
## Kernel binding -> bufs-key map (authoritative layout is erosion_transport_sphere3d.glsl):
##   0 SuspIn=susp[live] · 1 SuspOut=susp[back] · 2 Water=water[LIVE] · 3 Solid=solid · 4 Static=static ·
##   5 Send=send · 15 Neigh=nbr
## Push constant: { cell_count, pass_id, enabled, 0 }.
##
## Water is bound LIVE, not back: the flux this pass rides is the one the water CA took, and the CA computed
## it from the live half. The back half is the head left over AFTER that flow equalised it. See the kernel
## header — this is the difference between a working transport leg and a token one.
##
## `LA_EROSION_TRANSPORT=0` turns the advection OFF while leaving the dispatch, the buffers and the ping-pong
## carry exactly as they are (pass 0 zeroes its sends, so pass 1 degenerates to susp_out = susp_in). It exists
## so the transport leg can be A/B'd against itself in ONE build, at one seed, on one machine — the arm this
## repo's measurement rules ask for. It is a measurement control, not a fallback: the sim always ships with
## transport on.
## (Explicit types only, no ':=' inferred typing.)

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/erosion_transport_sphere3d.glsl"

var _rd: RenderingDevice = null
var _shader: RID = RID()
var _pipe: RID = RID()
var _set: Array = [RID(), RID()]        # one uniform set per ping-pong parity
var _enabled: int = 1


func setup(rd: RenderingDevice, bufs: Dictionary, _cc: int) -> void:
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
	var static_rid: RID = bufs.get("static", RID())
	var send_rid: RID = bufs.get("send", RID())
	var nbr_rid: RID = bufs.get("nbr", RID())
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
			[4, static_rid],         # Static (calm sea: receives, never sends)
			[5, send_rid],           # Shared outflow scratch (self-zeroed by pass 0)
			[15, nbr_rid],           # Neigh table
		])


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
