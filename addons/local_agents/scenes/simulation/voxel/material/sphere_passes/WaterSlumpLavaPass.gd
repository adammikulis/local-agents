extends RefCounted

## Cubed-sphere GPU pass plugin: the three finite-volume mass-transport CAs — water, granular slump, and
## lava flow — wired to the SphereGPU driver via the PLUGIN CONTRACT (setup() once, dispatch() each step).
##
## The driver owns the RenderingDevice, all channel buffers, and the compute list. This plugin only:
##   1. setup(): compiles the three cubed-sphere kernels, then builds TWO uniform sets per kernel (one per
##      parity), mapping each kernel's .glsl binding indices onto the driver's shared `bufs` buffers.
##   2. dispatch(): records the three 2-pass gathers into the driver's open compute list `cl`.
##
## All three kernels are the sphere ports of the box finite-volume CAs and follow the SAME two-pass GATHER
## structure: pass 0 records per-direction OUTFLOW into the shared `send` scratch (idx*6 + dir), a barrier,
## then pass 1 = old - own_out + received INFLOW into the ping-pong BACK buffer. They all share the single
## `send` scratch — no external clear is needed: every kernel's pass 0 unconditionally zeroes all 6 of its
## own send slots (idx*6+0..5) before any early-return, so the buffer is fully re-initialised each pass. That
## lets the three CAs run back-to-back in ONE open compute list without a buffer_clear (which is illegal while
## a compute list is open). Order: water, then slump, then lava.
##
## Per-kernel binding -> bufs-key map (see the .glsl headers for the authoritative layout):
##   water_sphere3d:      0 WaterIn=water[live] · 1 Solid=solid · 2 Static=static · 3 Send=send ·
##                        4 WaterOut=water[back] · 15 Neigh=nbr
##   slump_sphere3d:      0 SedIn=sediment[live] · 1 Solid=solid · 2 Send=send · 3 SedOut=sediment[back] ·
##                        15 Neigh=nbr
##   lava_flow_sphere3d:  0 LavaIn=lava[live] · 1 Solid=solid · 2 Send=send · 3 LavaOut=lava[back] ·
##                        4 Temp=temp[live] (carry-heat, in-place read/modify) · 15 Neigh=nbr
##
## Push constant (all three): PackedInt32Array([cell_count, pass_id, 0, 0]).to_byte_array().

const WATER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/water_sphere3d.glsl"
const SLUMP_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/slump_sphere3d.glsl"
const LAVA_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/lava_flow_sphere3d.glsl"

var _rd: RenderingDevice = null

# Compiled shaders (kept so their RIDs stay owned for the pipeline's lifetime).
var _water_shader: RID = RID()
var _slump_shader: RID = RID()
var _lava_shader: RID = RID()

# Compute pipelines.
var _water_pipe: RID = RID()
var _slump_pipe: RID = RID()
var _lava_pipe: RID = RID()

# Uniform sets, one per parity p in [0, 1].
var _water_set: Array = [RID(), RID()]
var _slump_set: Array = [RID(), RID()]
var _lava_set: Array = [RID(), RID()]

# Shared outflow scratch (idx*6 + dir). Self-cleared by each kernel's pass 0 — no external buffer_clear.
var _send: RID = RID()


func setup(rd: RenderingDevice, bufs: Dictionary, cc: int) -> void:
	_rd = rd
	if _rd == null:
		push_error("WaterSlumpLavaPass: null RenderingDevice")
		return

	_send = bufs.get("send", RID())  # the SINGLE shared outflow scratch (float32, cc*6)

	# --- Compile the three kernels -------------------------------------------------
	var water_sf: RDShaderFile = load(WATER_PATH)
	_water_shader = _rd.shader_create_from_spirv(water_sf.get_spirv())
	_water_pipe = _rd.compute_pipeline_create(_water_shader)

	var slump_sf: RDShaderFile = load(SLUMP_PATH)
	_slump_shader = _rd.shader_create_from_spirv(slump_sf.get_spirv())
	_slump_pipe = _rd.compute_pipeline_create(_slump_shader)

	var lava_sf: RDShaderFile = load(LAVA_PATH)
	_lava_shader = _rd.shader_create_from_spirv(lava_sf.get_spirv())
	_lava_pipe = _rd.compute_pipeline_create(_lava_shader)

	# --- Resolve the shared SINGLE buffers once ------------------------------------
	var solid_rid: RID = bufs.get("solid", RID())
	var static_rid: RID = bufs.get("static", RID())
	var send_rid: RID = _send
	var nbr_rid: RID = bufs.get("nbr", RID())

	# PAIR channels: [live, back] per parity.
	var water_pair: Array = bufs.get("water", [RID(), RID()])
	var sediment_pair: Array = bufs.get("sediment", [RID(), RID()])
	var lava_pair: Array = bufs.get("lava", [RID(), RID()])
	var temp_pair: Array = bufs.get("temp", [RID(), RID()])

	# --- Two uniform sets per kernel (one per parity) ------------------------------
	for p in 2:
		var back: int = 1 - p
		_water_set[p] = _build_set(_water_shader, [
			[0, water_pair[p]],      # WaterIn  = live water
			[1, solid_rid],          # Solid
			[2, static_rid],         # Static (infinite sink)
			[3, send_rid],           # Send scratch
			[4, water_pair[back]],   # WaterOut = back water
			[15, nbr_rid],           # Neigh table
		])
		_slump_set[p] = _build_set(_slump_shader, [
			[0, sediment_pair[p]],   # SedIn  = live sediment
			[1, solid_rid],          # Solid
			[2, send_rid],           # Send scratch
			[3, sediment_pair[back]], # SedOut = back sediment
			[15, nbr_rid],           # Neigh table
		])
		_lava_set[p] = _build_set(_lava_shader, [
			[0, lava_pair[p]],       # LavaIn  = live lava
			[1, solid_rid],          # Solid
			[2, send_rid],           # Send scratch
			[3, lava_pair[back]],    # LavaOut = back lava
			[4, temp_pair[p]],       # Temp    = live temp (carry-heat, in-place read/modify)
			[15, nbr_rid],           # Neigh table
		])


func dispatch(rd: RenderingDevice, cl: int, parity: int, _ctx: Dictionary, cc: int, groups: int) -> void:
	if _rd == null:
		return
	# Each CA is a 2-pass gather sharing the single `send` scratch (each pass 0 self-zeroes it). Order: water, slump, lava.
	_two_pass(rd, cl, _water_pipe, _water_set[parity], cc, groups)
	_two_pass(rd, cl, _slump_pipe, _slump_set[parity], cc, groups)
	_two_pass(rd, cl, _lava_pipe, _lava_set[parity], cc, groups)


## Free every RID this pass owns (uniform sets, then pipelines, then shaders), in dependent-first order,
## before the driver drops the local RenderingDevice. The `send` scratch is BORROWED from the driver's
## `bufs` (not created here) so it is NOT freed here — the driver frees it.
func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for s: Array in [_water_set, _slump_set, _lava_set]:
		for r in s:
			if r is RID and r.is_valid():
				rd.free_rid(r)
	_water_set = [RID(), RID()]
	_slump_set = [RID(), RID()]
	_lava_set = [RID(), RID()]
	for r: RID in [_water_pipe, _slump_pipe, _lava_pipe,
			_water_shader, _slump_shader, _lava_shader]:
		if r.is_valid():
			rd.free_rid(r)
	_water_pipe = RID()
	_slump_pipe = RID()
	_lava_pipe = RID()
	_water_shader = RID()
	_slump_shader = RID()
	_lava_shader = RID()


# --- helpers ------------------------------------------------------------------

## Records one 2-pass finite-volume CA into the open compute list: run pass 0 (outflow -> send), barrier, run
## pass 1 (inflow -> back buffer), barrier. Pass 0 self-zeroes all 6 send slots per cell before writing, so no
## buffer_clear is needed (and none is legal while a compute list is open). Bindings are re-bound each pass so
## a push-constant change is unambiguous; the barrier after pass 0 makes the outflow writes visible to pass 1's
## neighbour reads, and the barrier after pass 1 orders the back-buffer + shared-send writes ahead of the next kernel.
func _two_pass(rd: RenderingDevice, cl: int, pipe: RID, uset: RID, cc: int, groups: int) -> void:
	# PASS 0 — outflow
	rd.compute_list_bind_compute_pipeline(cl, pipe)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	var pc0: PackedByteArray = _pc(cc, 0)
	rd.compute_list_set_push_constant(cl, pc0, pc0.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)

	# PASS 1 — inflow / apply
	rd.compute_list_bind_compute_pipeline(cl, pipe)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	var pc1: PackedByteArray = _pc(cc, 1)
	rd.compute_list_set_push_constant(cl, pc1, pc1.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)


## Builds a uniform set from a list of [binding, rid] pairs bound to the shader's set 0.
func _build_set(shader: RID, entries: Array) -> RID:
	var uniforms: Array = []
	for e in entries:
		var binding: int = e[0]
		var buf: RID = e[1]
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = binding
		u.add_id(buf)
		uniforms.append(u)
	return _rd.uniform_set_create(uniforms, shader, 0)


func _pc(cc: int, pass_id: int) -> PackedByteArray:
	return PackedInt32Array([cc, pass_id, 0, 0]).to_byte_array()
