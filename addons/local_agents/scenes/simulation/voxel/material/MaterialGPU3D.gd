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
const LOCAL_SIZE_X: int = 64

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

var _heat_pipeline: RID = RID()
var _solar_pipeline: RID = RID()
var _buoy_pipeline: RID = RID()
var _cool_pipeline: RID = RID()
var _water_pipeline: RID = RID()
var _shaders: Array[RID] = []              # every compiled shader RID (freed in dispose)

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
var _buf_send: RID = RID()                 # cell_count * 6 floats: per-direction outflow

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
	_sea_level = field._sea_level
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


func _pipeline(path: String) -> RID:
	var shader_file: RDShaderFile = load(path)
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	var shader: RID = _rd.shader_create_from_spirv(spirv)
	_shaders.append(shader)
	return _rd.compute_pipeline_create(shader)


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


# uniform_set_create needs the SHADER RID, not the pipeline. Shaders were appended in _pipeline() in the
# SAME order the pipelines were created (heat, solar, buoy, cool, water), so map pipeline -> shader by it.
func _shader_of(pipeline: RID) -> RID:
	if pipeline == _heat_pipeline:
		return _shaders[0]
	if pipeline == _solar_pipeline:
		return _shaders[1]
	if pipeline == _buoy_pipeline:
		return _shaders[2]
	if pipeline == _cool_pipeline:
		return _shaders[3]
	return _shaders[4]


func _free_buffers() -> void:
	if _rd == null:
		return
	for arr in [_heat_set, _solar_set, _buoy_set, _cool_set, _water_set]:
		for s in arr:
			if s.is_valid():
				_rd.free_rid(s)
	_heat_set = [RID(), RID()]
	_solar_set = [RID(), RID()]
	_buoy_set = [RID(), RID()]
	_cool_set = [RID(), RID()]
	_water_set = [RID(), RID()]
	for buf in [_buf_temp_a, _buf_temp_b, _buf_water_a, _buf_water_b,
			_buf_vapor_a, _buf_vapor_b, _buf_cloud_a, _buf_cloud_b,
			_buf_fog_a, _buf_fog_b, _buf_lava_a, _buf_lava_b,
			_buf_solid, _buf_static, _buf_send]:
		if buf.is_valid():
			_rd.free_rid(buf)
	_buf_temp_a = RID(); _buf_temp_b = RID()
	_buf_water_a = RID(); _buf_water_b = RID()
	_buf_vapor_a = RID(); _buf_vapor_b = RID()
	_buf_cloud_a = RID(); _buf_cloud_b = RID()
	_buf_fog_a = RID(); _buf_fog_b = RID()
	_buf_lava_a = RID(); _buf_lava_b = RID()
	_buf_solid = RID(); _buf_static = RID(); _buf_send = RID()
	_fields = {}
	_cell_count = 0
	_static_uploaded = false


## Release every GPU resource + the local RenderingDevice. Call when tearing the field down.
func dispose() -> void:
	if _rd == null:
		return
	_free_buffers()
	for pipe in [_heat_pipeline, _solar_pipeline, _buoy_pipeline, _cool_pipeline, _water_pipeline]:
		if pipe.is_valid():
			_rd.free_rid(pipe)
	for s in _shaders:
		if s.is_valid():
			_rd.free_rid(s)
	_shaders = []
	_heat_pipeline = RID(); _solar_pipeline = RID(); _buoy_pipeline = RID()
	_cool_pipeline = RID(); _water_pipeline = RID()
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
## add_heat, meteor splashes) into the live resident buffers, refresh the solar factor, and reset
## ping-pong parity. Cheap: two buffer_update copies, no dispatch, no sync.
func begin_frame(temp: PackedFloat32Array, water: PackedFloat32Array, solar: float = 0.6) -> void:
	_init_rd()
	if _rd == null:
		return
	if _field != null:
		_ensure_buffers(_field._dim_x, _field._dim_y, _field._dim_z)
	_solar = solar
	# Parity 0 => live data is in the *_a buffers; upload the fresh CPU state there.
	_parity = 0
	upload(_buf_temp_a, temp)
	upload(_buf_water_a, water)


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
	# Atmosphere (vapor/cloud/fog transport + condensation) and lava-flow passes plug in HERE. Bind
	# their pipeline + <name>_set[_parity] (built from live_buffer/back_buffer over the resident
	# vapor/cloud/fog/lava pairs), add a barrier if a later pass reads an earlier pass's writes, and
	# dispatch. Do NOT submit/sync here — end_frame() owns the single readback. The parity flip below
	# keeps every field consistent.
	# ===============================================================================================

	_rd.compute_list_end()
	# Flip parity: this step read the live buffers and wrote the other pair, which is now live.
	_parity = 1 - _parity


## Frame end: the ONLY submit + sync of the frame. Flushes every queued step, waits once, then reads the
## final temp + water off whichever ping-pong buffer is live. Returns {"temp": ..., "water": ...}.
func end_frame() -> Dictionary:
	if _rd == null or _cell_count == 0:
		return {"temp": PackedFloat32Array(), "water": PackedFloat32Array()}
	_rd.submit()
	_rd.sync()
	return {
		"temp": download(live_buffer("temp", _parity)),
		"water": download(live_buffer("water", _parity)),
	}


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
