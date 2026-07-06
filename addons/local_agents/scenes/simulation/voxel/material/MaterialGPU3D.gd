class_name LAMaterialGPU3D
extends RefCounted

## GPU-RESIDENT compute backend for the DENSE 3D MaterialField3D. Owns a LOCAL RenderingDevice
## (RenderingServer.create_local_rendering_device()), persistent SSBOs that live across the WHOLE run,
## the compiled compute pipelines, and pre-built ping-pong uniform sets. Every per-cell simulation loop
## the CPU oracle runs each step is ported to a GPU pass here; a frame batches N steps on-GPU and reads
## back ONCE. The kernels are race-free ports of MaterialField3D.gd + MaterialHeat3D.gd:
##   HEAT (full MaterialHeat3D.step(), in order):
##     kernels3d/heat3d.glsl          <- PART 1 conduction  (6-neighbour relax, double-buffered gather)
##     kernels3d/heat3d_solar.glsl    <- PART 2 solar/ambient at the column-top sky cell (per-column)
##     kernels3d/heat3d_buoyancy.glsl <- PART 3 buoyant convection of hot void (per-column ascending sweep)
##     kernels3d/heat3d_cool.glsl     <- PART 4 evaporative cooling of wet cells (per-cell)
##   WATER (full MaterialField3D.step_water()):
##     kernels3d/water3d.glsl         <- down / lateral level-out / up overflow (two-pass gather)
##
## ============================================================================================
## RESIDENT FRAME API — the whole point (readback happens AT MOST ONCE PER FRAME)
## ============================================================================================
## A frame is exactly: 1 upload block + N x (all passes) + 1 readback block. Call order per physics
## frame (N = the field's steps this frame, 1..MAX_STEPS_PER_FRAME):
##
##   gpu.begin_frame(temp, water, solar)   # cheap uploads of the CPU-mutated state into the live SSBOs;
##                                         #   `solar` = MaterialHeat3D._solar() (the sun factor the GPU
##                                         #   can't read). Resets ping-pong parity. Uploads do NOT stall.
##   for i in range(N): gpu.step()         # water CA + FULL heat (conduction->solar->buoyancy->cooling)
##                                         #   on the resident buffers, ping-ponging in place — NO readback,
##                                         #   NO submit, NO sync. Just queues compute work.
##   var out: Dictionary = gpu.end_frame() # the ONLY submit + sync + readback of the frame.
##   temp = out["temp"] ; water = out["water"]
##
## `solid` and `static` are the terrain rock mask + calm-sea sink mask; they rarely change, so they are
## uploaded ONCE in setup() (re-push with upload_static_state() if the terrain is carved). Only temp +
## water round-trip, once each way per frame.
##
## PARITY: the batched path reproduces N iterations of {MaterialField3D.step_water() then the FULL
## MaterialHeat3D.step()} to ~1e-3 vs the CPU oracle (water runs before heat each step, matching the
## field's _physics_process order, so heat's wet-cooling reads the post-flow water).
##
## ADD-A-PASS SEAM (for the atmosphere + lava kernels bolted on next): vapor/cloud/fog/lava already have
## resident ping-pong buffers (see `_fields`). To add a pass: (1) compile the kernel + pipeline in
## _init_rd(), (2) build its two ping-pong uniform sets in _ensure_buffers() with live_buffer()/
## back_buffer(), (3) record its dispatch(es) in step() at the marked seam. ONE global `_parity` flips
## once per step(), so every field ping-pongs in lockstep and stays mutually consistent.
##
## The CPU GDScript loops stay the correctness ORACLE + headless fallback: available() is false when no
## local RenderingDevice can be made (--headless / no-compute), so those environments keep the CPU rules.
##
## Index layout (matches MaterialField3D): idx = (iy*dim_z + iz)*dim_x + ix (X contiguous, then Z, then Y).
## (Explicit types only — no ':=' inferred typing.)
##
## The OLD per-call methods step_heat_conduction()/flow_water() are retained ONLY as the benchmark
## baseline (each does upload -> dispatch -> submit -> sync -> readback, a GPU->CPU stall EVERY call).

const HEAT_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/heat3d.glsl"
const SOLAR_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/heat3d_solar.glsl"
const BUOY_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/heat3d_buoyancy.glsl"
const COOL_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/heat3d_cool.glsl"
const WATER_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/water3d.glsl"
const EVAP_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/atmos_evap3d.glsl"
const TRANSPORT_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/atmos_transport3d.glsl"
const CONDENSE_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/atmos_condense3d.glsl"
const RAIN_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/atmos_rain3d.glsl"
const LAVA_FLOW_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/lava_flow3d.glsl"
const LAVA_PHASE_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/lava_phase3d.glsl"
const LOCAL_SIZE_X: int = 64

# Field timestep (MaterialField3D.STEP_DT = 1/STEP_HZ) — the atmosphere wind advection needs it to turn a
# world wind velocity into a per-step cell-fraction. Kept in sync with MaterialField3D.
const STEP_DT: float = 0.1
# Per-field atmosphere transport gains (copies of MaterialAtmosphere3D's constants), applied via the ONE
# shared atmos_transport3d kernel dispatched three times.
const VAPOR_DIFFUSE: float = 0.14
const CLOUD_DIFFUSE: float = 0.06
const FOG_DIFFUSE: float = 0.03
const VAPOR_RISE: float = 0.10
const CLOUD_RISE: float = 0.04
const VAPOR_WIND_GAIN: float = 1.0
const CLOUD_WIND_GAIN: float = 1.0
const FOG_WIND_GAIN: float = 0.5
const ORO_CONDENSE_GAIN: float = 1.3       # windward-slope condensation boost (mirrors MaterialAtmosphere3D)

var _rd: RenderingDevice = null
var _field = null                          # LAMaterialField3D (shared grid back-reference)
var _cell_count: int = 0
var _dim_x: int = 0
var _dim_y: int = 0
var _dim_z: int = 0

# Field constants captured at setup (the GPU kernels can't read the field). _solar is refreshed each
# begin_frame (it tracks the day/night sun); the rest are fixed geometry.
var _origin_y: float = 0.0
var _cell_size: float = 5.0
var _sea_level: float = 0.0
var _solar: float = 0.6
var _wind: Vector2 = Vector2.ZERO          # world XZ wind, refreshed each begin_frame (drives atmosphere advection)

var _heat_pipeline: RID = RID()
var _solar_pipeline: RID = RID()
var _buoy_pipeline: RID = RID()
var _cool_pipeline: RID = RID()
var _water_pipeline: RID = RID()
var _evap_pipeline: RID = RID()
var _transport_pipeline: RID = RID()
var _condense_pipeline: RID = RID()
var _rain_pipeline: RID = RID()
var _lava_flow_pipeline: RID = RID()
var _lava_phase_pipeline: RID = RID()
var _shaders: Array[RID] = []              # every compiled shader RID (freed in dispose)
var _pipeline_shader: Dictionary = {}      # pipeline RID -> its shader RID (for uniform_set_create)

# --- Persistent SSBOs (sized to _cell_count), created ONCE, kept resident across the whole run. -----
# EVERY dynamic field is a PING-PONG PAIR (a <-> b). ONE global `_parity` selects the live buffer for ALL
# fields, so they ping-pong in lockstep; a pass reads live_buffer(name) and writes back_buffer(name) and
# stays consistent after the single flip. temp + water are stepped now; vapor/cloud/fog/lava are resident
# but not yet stepped (their kernels plug into the step() seam later). solid/static are single MASK
# buffers uploaded ONCE. send = 6-float-per-cell per-direction outflow scratch (water gather).
var _buf_temp_a: RID = RID()
var _buf_temp_b: RID = RID()
var _buf_water_a: RID = RID()
var _buf_water_b: RID = RID()
var _buf_vapor_a: RID = RID()
var _buf_vapor_b: RID = RID()
var _buf_cloud_a: RID = RID()
var _buf_cloud_b: RID = RID()
var _buf_fog_a: RID = RID()
var _buf_fog_b: RID = RID()
var _buf_lava_a: RID = RID()
var _buf_lava_b: RID = RID()
var _buf_solid: RID = RID()                # byte->float mirror of _solid (1 = rock)
var _buf_static: RID = RID()               # byte->float mirror of _static (1 = calm sea sink)
var _buf_send: RID = RID()                 # cell_count * 6 floats: per-direction outflow (water AND lava reuse)
var _buf_rain: RID = RID()                 # cell_count floats: per-cell rain mass scratch (condense -> rain gather)

# name -> [rid_a, rid_b] for every ping-pong field, so future passes fetch buffers by name.
var _fields: Dictionary = {}

# Two pre-built uniform sets per kernel so we ping-pong by SELECTING a set, never recreating one.
#   parity 0: live data in *_a  -> conduction/water read a, write b; forcing passes act on b  (index 0)
#   parity 1: live data in *_b  -> conduction/water read b, write a; forcing passes act on a  (index 1)
var _heat_set: Array[RID] = [RID(), RID()]     # conduction: in=live, out=back
var _solar_set: Array[RID] = [RID(), RID()]    # in-place on back temp (+ solid)
var _buoy_set: Array[RID] = [RID(), RID()]     # in-place on back temp (+ solid)
var _cool_set: Array[RID] = [RID(), RID()]     # in-place on back temp (+ back water + solid)
var _water_set: Array[RID] = [RID(), RID()]    # in=live water, out=back water (+ solid/static/send)
# Atmosphere sets. evap: in=vapor live, out=vapor back. transport: dispatched 3x — vapor reads its post-evap
# back and writes the (now-free) live buffer as scratch; cloud/fog read their live and write back. condense:
# reads post-transport vapor(live)/cloud(back)/fog(back), writes final vapor(back) + rain scratch. rain: adds
# the gathered rain into back water.
var _evap_set: Array[RID] = [RID(), RID()]
var _transport_vapor_set: Array[RID] = [RID(), RID()]
var _transport_cloud_set: Array[RID] = [RID(), RID()]
var _transport_fog_set: Array[RID] = [RID(), RID()]
var _condense_set: Array[RID] = [RID(), RID()]
var _rain_set: Array[RID] = [RID(), RID()]
# Lava sets. flow: in=lava live, out=lava back (+ solid/send/back temp for carry-heat). phase: in-place on
# back lava + back temp + solid (solidify/sustain).
var _lava_flow_set: Array[RID] = [RID(), RID()]
var _lava_phase_set: Array[RID] = [RID(), RID()]
var _parity: int = 0                        # 0 -> live in *_a, 1 -> live in *_b
var _static_uploaded: bool = false


## True only when a local RenderingDevice can be created (false in --headless / no-compute → the caller
## keeps running the CPU modules). Probes with a throwaway device so it never leaks.
static func available() -> bool:
	var probe: RenderingDevice = RenderingServer.create_local_rendering_device()
	if probe == null:
		return false
	probe.free()
	return true


## Create the RenderingDevice + pipelines, size the persistent SSBOs to the field's cell_count, capture
## the field geometry constants, and upload the (rarely-changing) solid/static masks ONCE.
func setup(field) -> void:
	_field = field
	_origin_y = field._origin.y
	_cell_size = field._cell_size
	_sea_level = field.sea_level
	_init_rd()
	if _rd == null:
		return
	_ensure_buffers(field._dim_x, field._dim_y, field._dim_z)
	upload_static_state(field._solid, field._static)


func _init_rd() -> void:
	if _rd != null:
		return
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		return
	_heat_pipeline = _pipeline(HEAT_SHADER_PATH)
	_solar_pipeline = _pipeline(SOLAR_SHADER_PATH)
	_buoy_pipeline = _pipeline(BUOY_SHADER_PATH)
	_cool_pipeline = _pipeline(COOL_SHADER_PATH)
	_water_pipeline = _pipeline(WATER_SHADER_PATH)
	_evap_pipeline = _pipeline(EVAP_SHADER_PATH)
	_transport_pipeline = _pipeline(TRANSPORT_SHADER_PATH)
	_condense_pipeline = _pipeline(CONDENSE_SHADER_PATH)
	_rain_pipeline = _pipeline(RAIN_SHADER_PATH)
	_lava_flow_pipeline = _pipeline(LAVA_FLOW_SHADER_PATH)
	_lava_phase_pipeline = _pipeline(LAVA_PHASE_SHADER_PATH)


func _pipeline(path: String) -> RID:
	var shader_file: RDShaderFile = load(path)
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	var shader: RID = _rd.shader_create_from_spirv(spirv)
	_shaders.append(shader)
	var pipeline: RID = _rd.compute_pipeline_create(shader)
	_pipeline_shader[pipeline] = shader
	return pipeline


func _make_uniform(binding: int, buf: RID) -> RDUniform:
	var u: RDUniform = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u


# --- Ping-pong buffer lookup (used to build sets + by future passes) -------------------------------
# For parity p: live = *_a when p==0 else *_b; back = the other. Conduction/water READ live + WRITE back;
# the in-place forcing passes act on back (the buffer conduction just wrote).

func buffer_pair(name: String) -> Array:
	return _fields.get(name, [RID(), RID()])


func live_buffer(name: String, parity: int) -> RID:
	var pair: Array = buffer_pair(name)
	return pair[0] if parity == 0 else pair[1]


func back_buffer(name: String, parity: int) -> RID:
	var pair: Array = buffer_pair(name)
	return pair[1] if parity == 0 else pair[0]


## (Re)allocate the persistent SSBOs + the two ping-pong uniform sets per kernel when the volume size
## changes. Idempotent for a fixed size (does NOT recreate buffers on repeat calls — the whole point).
func _ensure_buffers(dim_x: int, dim_y: int, dim_z: int) -> void:
	if _rd == null:
		return
	var cell_count: int = dim_x * dim_y * dim_z
	if cell_count == _cell_count and _buf_temp_a.is_valid():
		_dim_x = dim_x
		_dim_y = dim_y
		_dim_z = dim_z
		return
	_free_buffers()
	_cell_count = cell_count
	_dim_x = dim_x
	_dim_y = dim_y
	_dim_z = dim_z

	var zero: PackedFloat32Array = PackedFloat32Array()
	zero.resize(cell_count)
	var zbytes: PackedByteArray = zero.to_byte_array()
	_buf_temp_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_temp_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_water_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_water_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_vapor_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_vapor_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_cloud_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_cloud_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_fog_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_fog_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_lava_a = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_lava_b = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_solid = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_static = _rd.storage_buffer_create(zbytes.size(), zbytes)
	var send_zero: PackedFloat32Array = PackedFloat32Array()
	send_zero.resize(cell_count * 6)
	var send_bytes: PackedByteArray = send_zero.to_byte_array()
	_buf_send = _rd.storage_buffer_create(send_bytes.size(), send_bytes)
	_buf_rain = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_static_uploaded = false

	_fields = {
		"temp": [_buf_temp_a, _buf_temp_b],
		"water": [_buf_water_a, _buf_water_b],
		"vapor": [_buf_vapor_a, _buf_vapor_b],
		"cloud": [_buf_cloud_a, _buf_cloud_b],
		"fog": [_buf_fog_a, _buf_fog_b],
		"lava": [_buf_lava_a, _buf_lava_b],
	}

	# Build the per-parity uniform sets. p=0: live=*_a, back=*_b. p=1: live=*_b, back=*_a.
	for p in [0, 1]:
		var temp_live: RID = live_buffer("temp", p)
		var temp_back: RID = back_buffer("temp", p)
		var water_live: RID = live_buffer("water", p)
		var water_back: RID = back_buffer("water", p)
		var vapor_live: RID = live_buffer("vapor", p)
		var vapor_back: RID = back_buffer("vapor", p)
		var cloud_live: RID = live_buffer("cloud", p)
		var cloud_back: RID = back_buffer("cloud", p)
		var fog_live: RID = live_buffer("fog", p)
		var fog_back: RID = back_buffer("fog", p)
		var lava_live: RID = live_buffer("lava", p)
		var lava_back: RID = back_buffer("lava", p)

		# Conduction: heat3d.glsl bindings 0 = in (live), 1 = out (back).
		_heat_set[p] = _rd.uniform_set_create(
			[_make_uniform(0, temp_live), _make_uniform(1, temp_back)], _shader_of(_heat_pipeline), 0)
		# Solar: heat3d_solar.glsl 0 = temp (back, in-place), 1 = solid.
		_solar_set[p] = _rd.uniform_set_create(
			[_make_uniform(0, temp_back), _make_uniform(1, _buf_solid)], _shader_of(_solar_pipeline), 0)
		# Buoyancy: heat3d_buoyancy.glsl 0 = temp (back, in-place), 1 = solid.
		_buoy_set[p] = _rd.uniform_set_create(
			[_make_uniform(0, temp_back), _make_uniform(1, _buf_solid)], _shader_of(_buoy_pipeline), 0)
		# Cooling: heat3d_cool.glsl 0 = temp (back, in-place), 1 = water (back = post-flow), 2 = solid.
		_cool_set[p] = _rd.uniform_set_create([
			_make_uniform(0, temp_back), _make_uniform(1, water_back),
			_make_uniform(2, _buf_solid)], _shader_of(_cool_pipeline), 0)
		# Water: water3d.glsl 0 = in (live), 1 = solid, 2 = static, 3 = send, 4 = out (back).
		_water_set[p] = _rd.uniform_set_create([
			_make_uniform(0, water_live), _make_uniform(1, _buf_solid),
			_make_uniform(2, _buf_static), _make_uniform(3, _buf_send),
			_make_uniform(4, water_back)], _shader_of(_water_pipeline), 0)

		# --- Atmosphere ---------------------------------------------------------
		# Evap: atmos_evap3d.glsl 0=vapor in(live), 1=temp(back post-heat), 2=water(back post-flow),
		# 3=solid, 4=static, 5=vapor out(back).
		_evap_set[p] = _rd.uniform_set_create([
			_make_uniform(0, vapor_live), _make_uniform(1, temp_back),
			_make_uniform(2, water_back), _make_uniform(3, _buf_solid),
			_make_uniform(4, _buf_static), _make_uniform(5, vapor_back)], _shader_of(_evap_pipeline), 0)
		# Transport: atmos_transport3d.glsl 0=in, 1=solid, 2=out. VAPOR reads its post-evap back and writes
		# the (now-free) live buffer as scratch; CLOUD/FOG read their live and write back.
		_transport_vapor_set[p] = _rd.uniform_set_create([
			_make_uniform(0, vapor_back), _make_uniform(1, _buf_solid),
			_make_uniform(2, vapor_live)], _shader_of(_transport_pipeline), 0)
		_transport_cloud_set[p] = _rd.uniform_set_create([
			_make_uniform(0, cloud_live), _make_uniform(1, _buf_solid),
			_make_uniform(2, cloud_back)], _shader_of(_transport_pipeline), 0)
		_transport_fog_set[p] = _rd.uniform_set_create([
			_make_uniform(0, fog_live), _make_uniform(1, _buf_solid),
			_make_uniform(2, fog_back)], _shader_of(_transport_pipeline), 0)
		# Condense: atmos_condense3d.glsl 0=vapor in(post-transport = live scratch), 1=cloud(back, in place),
		# 2=fog(back, in place), 3=temp(back), 4=water(back), 5=solid, 6=static, 7=vapor out(back), 8=rain.
		_condense_set[p] = _rd.uniform_set_create([
			_make_uniform(0, vapor_live), _make_uniform(1, cloud_back),
			_make_uniform(2, fog_back), _make_uniform(3, temp_back),
			_make_uniform(4, water_back), _make_uniform(5, _buf_solid),
			_make_uniform(6, _buf_static), _make_uniform(7, vapor_back),
			_make_uniform(8, _buf_rain)], _shader_of(_condense_pipeline), 0)
		# Rain: atmos_rain3d.glsl 0=rain, 1=solid, 2=water(back, in place +=).
		_rain_set[p] = _rd.uniform_set_create([
			_make_uniform(0, _buf_rain), _make_uniform(1, _buf_solid),
			_make_uniform(2, water_back)], _shader_of(_rain_pipeline), 0)

		# --- Lava ---------------------------------------------------------------
		# Flow: lava_flow3d.glsl 0=lava in(live), 1=solid, 2=send, 3=lava out(back), 4=temp(back, carry-heat).
		_lava_flow_set[p] = _rd.uniform_set_create([
			_make_uniform(0, lava_live), _make_uniform(1, _buf_solid),
			_make_uniform(2, _buf_send), _make_uniform(3, lava_back),
			_make_uniform(4, temp_back)], _shader_of(_lava_flow_pipeline), 0)
		# Phase (solidify + sustain): lava_phase3d.glsl 0=lava(back, in place), 1=temp(back, in place),
		# 2=solid(in place).
		_lava_phase_set[p] = _rd.uniform_set_create([
			_make_uniform(0, lava_back), _make_uniform(1, temp_back),
			_make_uniform(2, _buf_solid)], _shader_of(_lava_phase_pipeline), 0)


# uniform_set_create needs the SHADER RID, not the pipeline. _pipeline() records the pairing.
func _shader_of(pipeline: RID) -> RID:
	return _pipeline_shader.get(pipeline, RID())


func _free_buffers() -> void:
	if _rd == null:
		return
	for arr in [_heat_set, _solar_set, _buoy_set, _cool_set, _water_set,
			_evap_set, _transport_vapor_set, _transport_cloud_set, _transport_fog_set,
			_condense_set, _rain_set, _lava_flow_set, _lava_phase_set]:
		for s in arr:
			if s.is_valid():
				_rd.free_rid(s)
	_heat_set = [RID(), RID()]
	_solar_set = [RID(), RID()]
	_buoy_set = [RID(), RID()]
	_cool_set = [RID(), RID()]
	_water_set = [RID(), RID()]
	_evap_set = [RID(), RID()]
	_transport_vapor_set = [RID(), RID()]
	_transport_cloud_set = [RID(), RID()]
	_transport_fog_set = [RID(), RID()]
	_condense_set = [RID(), RID()]
	_rain_set = [RID(), RID()]
	_lava_flow_set = [RID(), RID()]
	_lava_phase_set = [RID(), RID()]
	for buf in [_buf_temp_a, _buf_temp_b, _buf_water_a, _buf_water_b,
			_buf_vapor_a, _buf_vapor_b, _buf_cloud_a, _buf_cloud_b,
			_buf_fog_a, _buf_fog_b, _buf_lava_a, _buf_lava_b,
			_buf_solid, _buf_static, _buf_send, _buf_rain]:
		if buf.is_valid():
			_rd.free_rid(buf)
	_buf_temp_a = RID(); _buf_temp_b = RID()
	_buf_water_a = RID(); _buf_water_b = RID()
	_buf_vapor_a = RID(); _buf_vapor_b = RID()
	_buf_cloud_a = RID(); _buf_cloud_b = RID()
	_buf_fog_a = RID(); _buf_fog_b = RID()
	_buf_lava_a = RID(); _buf_lava_b = RID()
	_buf_solid = RID(); _buf_static = RID(); _buf_send = RID(); _buf_rain = RID()
	_fields = {}
	_cell_count = 0
	_static_uploaded = false


## Release every GPU resource + the local RenderingDevice. Call when tearing the field down.
func dispose() -> void:
	if _rd == null:
		return
	_free_buffers()
	for pipe in [_heat_pipeline, _solar_pipeline, _buoy_pipeline, _cool_pipeline, _water_pipeline,
			_evap_pipeline, _transport_pipeline, _condense_pipeline, _rain_pipeline,
			_lava_flow_pipeline, _lava_phase_pipeline]:
		if pipe.is_valid():
			_rd.free_rid(pipe)
	for s in _shaders:
		if s.is_valid():
			_rd.free_rid(s)
	_shaders = []
	_pipeline_shader = {}
	_heat_pipeline = RID(); _solar_pipeline = RID(); _buoy_pipeline = RID()
	_cool_pipeline = RID(); _water_pipeline = RID()
	_evap_pipeline = RID(); _transport_pipeline = RID(); _condense_pipeline = RID()
	_rain_pipeline = RID(); _lava_flow_pipeline = RID(); _lava_phase_pipeline = RID()
	_rd.free()
	_rd = null


# --- Buffer transfer helpers -----------------------------------------------------------------------

## Upload a flat grid into an SSBO (native byte copy). Uploads do NOT stall the GPU (no sync).
func upload(buf: RID, arr: PackedFloat32Array) -> void:
	if _rd == null:
		return
	var bytes: PackedByteArray = arr.to_byte_array()
	_rd.buffer_update(buf, 0, bytes.size(), bytes)


## Download an SSBO back to a flat grid. This is the ONLY GPU->CPU sync stall — do it at most once per
## frame per field (temp + water in end_frame).
func download(buf: RID) -> PackedFloat32Array:
	if _rd == null:
		return PackedFloat32Array()
	var bytes: PackedByteArray = _rd.buffer_get_data(buf)
	return bytes.to_float32_array()


func _bytes_to_floats(b: PackedByteArray) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(b.size())
	for k in range(b.size()):
		out[k] = float(b[k])
	return out


func _groups() -> int:
	return int(ceil(float(_cell_count) / float(LOCAL_SIZE_X)))


func _col_groups() -> int:
	return int(ceil(float(_dim_x * _dim_z) / float(LOCAL_SIZE_X)))


## Push the (rarely-changing) rock + calm-sea masks into their resident SSBOs. Called once from setup();
## call again ONLY if the terrain is carved or the sea reseeded. Not part of the per-frame path.
func upload_static_state(solid: PackedByteArray, static_cells: PackedByteArray) -> void:
	if _rd == null:
		return
	upload(_buf_solid, _bytes_to_floats(solid))
	upload(_buf_static, _bytes_to_floats(static_cells))
	_static_uploaded = true


# --- RESIDENT FRAME API (begin_frame -> step x N -> end_frame) -------------------------------------

## Frame start: upload the CPU-authoritative temp + water (which carry this frame's injections — springs,
## add_heat, meteor splashes) into the CURRENT live resident buffers, and refresh the solar + wind scalars.
## Cheap: two buffer_update copies, no dispatch, no sync. Parity is NOT reset — vapor / cloud / fog / lava
## are fully resident (they persist on the GPU across frames, ping-ponging in lockstep), so uploading temp
## and water into whichever buffer is currently live keeps every field consistent with the last end_frame.
## Seed the resident fields (and push per-frame injections into them) with set_field(); `wind` (world XZ)
## drives the atmosphere advection.
func begin_frame(temp: PackedFloat32Array, water: PackedFloat32Array, solar: float = 0.6, wind: Vector2 = Vector2.ZERO) -> void:
	_init_rd()
	if _rd == null:
		return
	if _field != null:
		_ensure_buffers(_field._dim_x, _field._dim_y, _field._dim_z)
	_solar = solar
	_wind = wind
	upload(live_buffer("temp", _parity), temp)
	upload(live_buffer("water", _parity), water)


## Seed / inject a resident field (temp / water / vapor / cloud / fog / lava) into its CURRENT live buffer.
## Use it to upload the initial vapor/cloud/fog/lava state once, or to fold a CPU-side injection (an
## add_lava vent, a spring) into the resident buffer before the step loop. No dispatch, no sync.
func set_field(name: String, arr: PackedFloat32Array) -> void:
	if _rd == null:
		return
	upload(live_buffer(name, _parity), arr)


## One resident sim step, queued into a compute list (no submit/sync/readback). Order mirrors the field's
## _physics_process: WATER first, then the FULL heat chain (conduction -> solar -> buoyancy -> cooling),
## so heat's wet-cooling reads the post-flow water. Ping-pongs in place, then flips parity. Successive
## steps run in separate compute lists; Godot inserts a full memory barrier between compute lists, so
## step k+1 correctly reads what step k wrote.
func step() -> void:
	if _rd == null or _cell_count == 0:
		return
	var groups: int = _groups()
	var col_groups: int = _col_groups()
	var cl: int = _rd.compute_list_begin()

	# --- WATER CA: pass 0 outflow -> barrier -> pass 1 gather+apply. water[live] -> water[back]. ---
	_rd.compute_list_bind_compute_pipeline(cl, _water_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _water_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, _water_pc(0), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)
	_rd.compute_list_bind_compute_pipeline(cl, _water_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _water_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, _water_pc(1), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)

	# --- HEAT PART 1: conduction. temp[live] -> temp[back]. (Disjoint from water; no barrier needed
	# between the water writes and the conduction reads — they touch different buffers.) ---
	_rd.compute_list_bind_compute_pipeline(cl, _heat_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _heat_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, _heat_pc(), 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # conduction (and water pass1) visible to the forcing passes

	# --- HEAT PART 2: solar/ambient at the column-top sky cell. In-place on temp[back]. Per-column. ---
	_rd.compute_list_bind_compute_pipeline(cl, _solar_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _solar_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, _solar_pc(), 32)
	_rd.compute_list_dispatch(cl, col_groups, 1, 1)
	_rd.compute_list_add_barrier(cl)

	# --- HEAT PART 3: buoyant convection. In-place on temp[back]. Per-column ascending sweep. ---
	_rd.compute_list_bind_compute_pipeline(cl, _buoy_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _buoy_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, _dims_pc(), 16)
	_rd.compute_list_dispatch(cl, col_groups, 1, 1)
	_rd.compute_list_add_barrier(cl)

	# --- HEAT PART 4: evaporative cooling of wet cells. In-place on temp[back], reads water[back]. ---
	_rd.compute_list_bind_compute_pipeline(cl, _cool_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _cool_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, _dims_pc(), 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)

	# ================= ADD-A-PASS SEAM ==============================================================
	# ATMOSPHERE then LAVA (matching MaterialField3D._physics_process order: water -> heat -> atmosphere
	# -> lava). A barrier already separated the heat forcing passes above; a fresh one guards the temp
	# writes (post-heat temp is what evap/condense read).
	_rd.compute_list_add_barrier(cl)

	# --- ATMOSPHERE STAGE 1: EVAPORATION. vapor[live] + evap -> vapor[back]. ---
	_rd.compute_list_bind_compute_pipeline(cl, _evap_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _evap_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, _dims_pc(), 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # post-evap vapor visible to its transport read

	# --- ATMOSPHERE STAGE 2: TRANSPORT (vapor / cloud / fog). Each reads a snapshot, writes a disjoint
	# buffer; the three are mutually independent so no barrier is needed BETWEEN them. ---
	_rd.compute_list_bind_compute_pipeline(cl, _transport_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _transport_vapor_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, _transport_pc(VAPOR_DIFFUSE, VAPOR_RISE, VAPOR_WIND_GAIN), 48)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_bind_uniform_set(cl, _transport_cloud_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, _transport_pc(CLOUD_DIFFUSE, CLOUD_RISE, CLOUD_WIND_GAIN), 48)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_bind_uniform_set(cl, _transport_fog_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, _transport_pc(FOG_DIFFUSE, 0.0, FOG_WIND_GAIN), 48)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # post-transport vapor/cloud/fog visible to condensation

	# --- ATMOSPHERE STAGE 3: CONDENSATION + rain accounting. Per void cell: dewpoint condense/re-evap/
	# decay + compute rain (stored to the rain scratch). vapor[live] -> vapor[back]; cloud/fog[back] in place. ---
	_rd.compute_list_bind_compute_pipeline(cl, _condense_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _condense_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, _condense_pc(), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # rain scratch visible to the rain gather

	# --- ATMOSPHERE STAGE 4: RAIN GATHER. Route each cell's rain to the ground cell: water[back] += rain. ---
	_rd.compute_list_bind_compute_pipeline(cl, _rain_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _rain_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, _dims_pc(), 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # temp[back] carry-heat / water[back] settle before lava reads

	# --- LAVA FLOW: viscous 3D CA, two-pass gather (reuses the water send buffer). lava[live] ->
	# lava[back]; a receiving cell's temp[back] is floored to MOLTEN_FLOOR (carry-heat). ---
	_rd.compute_list_bind_compute_pipeline(cl, _lava_flow_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _lava_flow_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, _lava_pc(0), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)
	_rd.compute_list_bind_compute_pipeline(cl, _lava_flow_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _lava_flow_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, _lava_pc(1), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)          # post-flow lava/temp visible to solidify+sustain

	# --- LAVA PHASE: solidify (cooled lava -> rock) + sustain (keep remaining lava molten), in place. ---
	_rd.compute_list_bind_compute_pipeline(cl, _lava_phase_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _lava_phase_set[_parity], 0)
	_rd.compute_list_set_push_constant(cl, _dims_pc(), 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	# ===============================================================================================

	_rd.compute_list_end()
	# Flip parity: this step read the live buffers and wrote the other pair, which is now live.
	_parity = 1 - _parity


## Frame end: the ONLY submit + sync of the frame. Flushes every queued step, waits once, then reads the
## final resident state off whichever ping-pong buffer is live. Returns the full per-cell sim output:
## {"temp", "water", "vapor", "cloud", "fog", "lava"} (temp+water round-trip via begin_frame; the airborne
## fields + lava are resident and returned so the renderer / rain layer / lava visuals can consume them).
func end_frame(read_vapor: bool = true, read_cloud: bool = true, read_fog: bool = true) -> Dictionary:
	if _rd == null or _cell_count == 0:
		return {
			"temp": PackedFloat32Array(), "water": PackedFloat32Array(),
			"vapor": PackedFloat32Array(), "cloud": PackedFloat32Array(),
			"fog": PackedFloat32Array(), "lava": PackedFloat32Array(),
		}
	_rd.submit()
	_rd.sync()
	# temp / water / lava are consumer-queried continuously -> always read. vapor / cloud / fog are render-
	# only + GPU-resident (they don't feed the next step), so the caller throttles their readback; unread
	# fields are simply omitted and the caller keeps its previous (slightly stale) CPU copy.
	var out: Dictionary = {
		"temp": download(live_buffer("temp", _parity)),
		"water": download(live_buffer("water", _parity)),
		"lava": download(live_buffer("lava", _parity)),
	}
	if read_vapor:
		out["vapor"] = download(live_buffer("vapor", _parity))
	if read_cloud:
		out["cloud"] = download(live_buffer("cloud", _parity))
	if read_fog:
		out["fog"] = download(live_buffer("fog", _parity))
	return out


func _heat_pc() -> PackedByteArray:
	return _dims_pc()


func _dims_pc() -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, _dim_x)
	pc.encode_u32(4, _dim_y)
	pc.encode_u32(8, _dim_z)
	pc.encode_u32(12, _cell_count)
	return pc


# Condensation push-constant: dims + the world XZ wind + orographic gain (windward-slope uplift test).
func _condense_pc() -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, _dim_x)
	pc.encode_u32(4, _dim_y)
	pc.encode_u32(8, _dim_z)
	pc.encode_u32(12, _cell_count)
	pc.encode_float(16, _wind.x)
	pc.encode_float(20, _wind.y)
	pc.encode_float(24, ORO_CONDENSE_GAIN)
	pc.encode_float(28, 0.0)
	return pc


func _solar_pc() -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_float(0, _solar)
	pc.encode_float(4, _origin_y)
	pc.encode_float(8, _cell_size)
	pc.encode_float(12, _sea_level)
	pc.encode_u32(16, _dim_x)
	pc.encode_u32(20, _dim_y)
	pc.encode_u32(24, _dim_z)
	pc.encode_u32(28, _dim_x * _dim_z)
	return pc


func _water_pc(pass_id: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, _dim_x)
	pc.encode_u32(4, _dim_y)
	pc.encode_u32(8, _dim_z)
	pc.encode_u32(12, _cell_count)
	pc.encode_u32(16, pass_id)
	pc.encode_u32(20, 0)
	pc.encode_u32(24, 0)
	pc.encode_u32(28, 0)
	return pc


# Lava flow shares the water push-constant shape (dims + pass_id).
func _lava_pc(pass_id: int) -> PackedByteArray:
	return _water_pc(pass_id)


# Atmosphere transport push-constant: dims + this field's diffuse/rise fractions + the precomputed
# horizontal wind shares ax/az (clamped 0..0.5) and signs sx/sz. Mirrors MaterialAtmosphere3D._transport:
# ax = clamp(|wind.x| * wind_gain * STEP_DT / cell_size, 0, 0.5); sx = sign(wind.x).
func _transport_pc(diffuse_frac: float, rise_frac: float, wind_gain: float) -> PackedByteArray:
	var cs: float = _cell_size if _cell_size > 0.0 else 1.0
	var ax: float = clampf(absf(_wind.x) * wind_gain * STEP_DT / cs, 0.0, 0.5)
	var az: float = clampf(absf(_wind.y) * wind_gain * STEP_DT / cs, 0.0, 0.5)
	var sx: int = 1 if _wind.x > 0.0 else -1
	var sz: int = 1 if _wind.y > 0.0 else -1
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(48)
	pc.encode_u32(0, _dim_x)
	pc.encode_u32(4, _dim_y)
	pc.encode_u32(8, _dim_z)
	pc.encode_u32(12, _cell_count)
	pc.encode_float(16, diffuse_frac)
	pc.encode_float(20, rise_frac)
	pc.encode_float(24, ax)
	pc.encode_float(28, az)
	pc.encode_s32(32, sx)
	pc.encode_s32(36, sz)
	pc.encode_u32(40, 0)
	pc.encode_u32(44, 0)
	return pc


# --- OLD per-call API (BENCHMARK BASELINE ONLY — do NOT use on the hot path) ------------------------
# Each does a full upload -> dispatch -> submit -> sync -> readback, i.e. a GPU->CPU stall EVERY call.
# Kept so the micro-benchmark can compare this pattern against the resident begin/step/end path. They
# reuse the *_a -> *_b buffers via uniform-set index 0. NOTE: step_heat_conduction covers ONLY the
# conduction pass (the original narrow port) — the resident step() runs the FULL heat chain.

## OLD: one 6-neighbour heat CONDUCTION pass with per-call upload + readback. Baseline only.
func step_heat_conduction(temp: PackedFloat32Array, solid: PackedByteArray, dims: Vector3i) -> PackedFloat32Array:
	_init_rd()
	if _rd == null:
		return PackedFloat32Array()
	_ensure_buffers(dims.x, dims.y, dims.z)
	upload(_buf_temp_a, temp)

	var groups: int = _groups()
	var cl: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _heat_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _heat_set[0], 0)
	_rd.compute_list_set_push_constant(cl, _heat_pc(), 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	return download(_buf_temp_b)


## OLD: one water CA step with per-call upload (incl. solid/static) + readback. Baseline only.
func flow_water(water: PackedFloat32Array, solid: PackedByteArray, static_cells: PackedByteArray, dims: Vector3i) -> PackedFloat32Array:
	_init_rd()
	if _rd == null:
		return PackedFloat32Array()
	_ensure_buffers(dims.x, dims.y, dims.z)
	upload(_buf_water_a, water)
	upload(_buf_solid, _bytes_to_floats(solid))
	upload(_buf_static, _bytes_to_floats(static_cells))

	var groups: int = _groups()
	var cl: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _water_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _water_set[0], 0)
	_rd.compute_list_set_push_constant(cl, _water_pc(0), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)
	_rd.compute_list_bind_compute_pipeline(cl, _water_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _water_set[0], 0)
	_rd.compute_list_set_push_constant(cl, _water_pc(1), 32)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	return download(_buf_water_b)
