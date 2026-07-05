class_name LAMaterialGPU
extends RefCounted

## GPU compute backend for the MaterialField's hot loops (Phase 1: heat; Phase 2: + atmosphere).
##
## Owns a LOCAL RenderingDevice (RenderingServer.create_local_rendering_device()), the SSBOs mirroring
## the field's flat PackedFloat32Array grids, the compiled compute pipelines and their uniform sets.
## The kernels are race-free GATHER ports of the CPU modules:
##   - kernels/heat.glsl      <- MaterialHeat.step()          (conduction + ambient relax + wet cooling)
##   - kernels/transport.glsl <- MaterialAtmosphere._transport (diffusion + upwind wind advection)
##   - kernels/condense.glsl  <- MaterialAtmosphere.step()     (saturation/condense/re-evap/precip/decay)
## The CPU modules stay the correctness oracle + the headless fallback (available() is false when no
## local RenderingDevice can be made, so --headless runs the CPU modules). (Explicit types only — no ':='.)
##
## GPU RESIDENCY: temp, vapor, cloud, fog, water live in persistent SSBOs. cloud/fog are written ONLY by
## the atmosphere kernels and read by the heat kernel for sun-shading, so they never round-trip to the
## CPU except a single download after the atmosphere step (for the cloud sheets + cover means). The heat
## kernel reads the GPU-resident cloud/fog the atmosphere produced last step — the Phase 2 amortization.
## (The liquid CA still runs on the CPU BETWEEN heat and atmosphere and mutates temp/water/vapor, so
## those are re-uploaded before the atmosphere kernels to preserve exact CPU ordering — Phase 3 moves
## liquid onto the GPU to collapse that into one submit.)

const Mat: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/Materials.gd")
const AtmoScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialAtmosphere.gd")

const HEAT_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels/heat.glsl"
const TRANSPORT_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels/transport.glsl"
const CONDENSE_SHADER_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels/condense.glsl"
const LOCAL_SIZE_X: int = 64

var _rd: RenderingDevice = null
var _field = null                          # LAMaterialField (shared grid back-reference)
var _cell_count: int = 0

var _heat_shader: RID = RID()
var _heat_pipeline: RID = RID()
var _heat_set: RID = RID()

var _transport_shader: RID = RID()
var _transport_pipeline: RID = RID()
var _transport_set_vapor: RID = RID()
var _transport_set_cloud: RID = RID()
var _transport_set_fog: RID = RID()

var _condense_shader: RID = RID()
var _condense_pipeline: RID = RID()
var _condense_set: RID = RID()

# Persistent SSBOs. temp is double-buffered (in -> out) so the heat gather never reads a neighbour
# another invocation is writing; each transported field (vapor/cloud/fog) has an _out scratch for the
# same reason, and condense reads those _out buffers and writes the canonical ones.
var _buf_temp_in: RID = RID()
var _buf_temp_out: RID = RID()
var _buf_terrain: RID = RID()
var _buf_sampled: RID = RID()
var _buf_vapor: RID = RID()
var _buf_vapor_out: RID = RID()
var _buf_cloud: RID = RID()
var _buf_cloud_out: RID = RID()
var _buf_fog: RID = RID()
var _buf_fog_out: RID = RID()
var _buf_water: RID = RID()
var _buf_stats: RID = RID()                 # one uint: "did it rain this step" flag

# _sampled is a PackedByteArray on the field; converting it to floats is the one non-native transform,
# so cache the float mirror and rebuild it only when the sampled set actually grows.
var _sampled_floats: PackedFloat32Array = PackedFloat32Array()
var _sampled_synced_count: int = -1


## True only when a local RenderingDevice can be created (false in --headless / no-compute → the caller
## keeps running the CPU modules). Probes with a throwaway device so it never leaks.
static func available() -> bool:
	var probe: RenderingDevice = RenderingServer.create_local_rendering_device()
	if probe == null:
		return false
	probe.free()
	return true


## Allocate the SSBOs (sized to _cell_count), compile the pipelines, build the uniform sets.
func setup(field) -> void:
	_field = field
	_cell_count = field._cell_count
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		return

	_heat_shader = _compile(HEAT_SHADER_PATH)
	_heat_pipeline = _rd.compute_pipeline_create(_heat_shader)
	_transport_shader = _compile(TRANSPORT_SHADER_PATH)
	_transport_pipeline = _rd.compute_pipeline_create(_transport_shader)
	_condense_shader = _compile(CONDENSE_SHADER_PATH)
	_condense_pipeline = _rd.compute_pipeline_create(_condense_shader)

	var zero: PackedFloat32Array = PackedFloat32Array()
	zero.resize(_cell_count)
	var zbytes: PackedByteArray = zero.to_byte_array()
	_buf_temp_in = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_temp_out = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_terrain = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_sampled = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_vapor = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_vapor_out = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_cloud = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_cloud_out = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_fog = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_fog_out = _rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_water = _rd.storage_buffer_create(zbytes.size(), zbytes)
	var stats_zero: PackedByteArray = PackedByteArray()
	stats_zero.resize(4)
	_buf_stats = _rd.storage_buffer_create(stats_zero.size(), stats_zero)

	# Heat uniform set (binding order matches heat.glsl).
	var hu: Array = []
	hu.append(_make_uniform(0, _buf_temp_in))
	hu.append(_make_uniform(1, _buf_temp_out))
	hu.append(_make_uniform(2, _buf_terrain))
	hu.append(_make_uniform(3, _buf_sampled))
	hu.append(_make_uniform(4, _buf_cloud))
	hu.append(_make_uniform(5, _buf_fog))
	hu.append(_make_uniform(6, _buf_water))
	_heat_set = _rd.uniform_set_create(hu, _heat_shader, 0)

	# One transport uniform set per transported field (in, out, sampled) — same pipeline, rebound.
	_transport_set_vapor = _make_transport_set(_buf_vapor, _buf_vapor_out)
	_transport_set_cloud = _make_transport_set(_buf_cloud, _buf_cloud_out)
	_transport_set_fog = _make_transport_set(_buf_fog, _buf_fog_out)

	# Condense uniform set (binding order matches condense.glsl).
	var cu: Array = []
	cu.append(_make_uniform(0, _buf_temp_in))     # post-liquid temp (re-uploaded before atmosphere)
	cu.append(_make_uniform(1, _buf_vapor_out))   # post-transport vapor
	cu.append(_make_uniform(2, _buf_cloud_out))
	cu.append(_make_uniform(3, _buf_fog_out))
	cu.append(_make_uniform(4, _buf_vapor))       # write canonical
	cu.append(_make_uniform(5, _buf_cloud))
	cu.append(_make_uniform(6, _buf_fog))
	cu.append(_make_uniform(7, _buf_water))
	cu.append(_make_uniform(8, _buf_sampled))
	cu.append(_make_uniform(9, _buf_stats))
	_condense_set = _rd.uniform_set_create(cu, _condense_shader, 0)


func _compile(path: String) -> RID:
	var shader_file: RDShaderFile = load(path)
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	return _rd.shader_create_from_spirv(spirv)


func _make_uniform(binding: int, buf: RID) -> RDUniform:
	var u: RDUniform = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u


func _make_transport_set(in_buf: RID, out_buf: RID) -> RID:
	var uniforms: Array = []
	uniforms.append(_make_uniform(0, in_buf))
	uniforms.append(_make_uniform(1, out_buf))
	uniforms.append(_make_uniform(2, _buf_sampled))
	return _rd.uniform_set_create(uniforms, _transport_shader, 0)


## Upload a flat grid into an SSBO (native byte copy).
func upload(buf: RID, arr: PackedFloat32Array) -> void:
	if _rd == null:
		return
	var bytes: PackedByteArray = arr.to_byte_array()
	_rd.buffer_update(buf, 0, bytes.size(), bytes)


## Download an SSBO back to a flat grid.
func download(buf: RID) -> PackedFloat32Array:
	if _rd == null:
		return PackedFloat32Array()
	var bytes: PackedByteArray = _rd.buffer_get_data(buf)
	return bytes.to_float32_array()


## Rebuild + re-upload the float mirror of _sampled only when the sampled set has grown.
func _sync_sampled() -> void:
	if _field._sampled_count == _sampled_synced_count:
		return
	_sampled_synced_count = _field._sampled_count
	_sampled_floats.resize(_cell_count)
	var s: PackedByteArray = _field._sampled
	for k in range(_cell_count):
		_sampled_floats[k] = float(s[k])
	upload(_buf_sampled, _sampled_floats)


## Run one heat step on the GPU. Uploads temp (CPU-authoritative — carries add_heat injections),
## terrain and water; reads the GPU-RESIDENT cloud/fog the atmosphere produced last step (no upload);
## downloads the result into _field._temp so the CPU liquid/combustion/render passes see it. `solar` ==
## the field's _solar_input() (the sun energy the GPU can't read itself).
func step_heat(solar: float) -> void:
	if _rd == null:
		return
	var f = _field
	_sync_sampled()
	upload(_buf_temp_in, f._temp)
	upload(_buf_terrain, f._terrain_h)
	upload(_buf_water, f._mat_array(Mat.WATER))

	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_float(0, solar)
	pc.encode_u32(4, f._dim)
	pc.encode_u32(8, _cell_count)
	pc.encode_float(12, 0.0)

	var groups: int = _groups()
	var cl: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _heat_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _heat_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	f._temp = download(_buf_temp_out)


## Run one atmosphere step on the GPU (called on the same cadence the CPU runs MaterialAtmosphere.step
## — every other material step). Transports vapor/cloud/fog (diffusion + wind), then condenses. Uploads
## the buffers the CPU liquid step mutated (temp, vapor, water); cloud/fog are GPU-resident. Downloads
## vapor/cloud/fog/water for the CPU consumers, recomputes the cover means on the CPU, and sets the
## water render-dirty flag when it rained. `wind` == MaterialAtmosphere._wind.
func step_atmosphere(wind: Vector2) -> void:
	if _rd == null:
		return
	var f = _field
	_sync_sampled()
	upload(_buf_temp_in, f._temp)                    # post-liquid temp for condensation
	upload(_buf_vapor, f._vapor)                      # post-liquid vapor (evaporation added)
	upload(_buf_water, f._mat_array(Mat.WATER))       # post-liquid water (flow + rain input)
	# cloud/fog are NOT uploaded — they are GPU-resident (only the atmosphere kernels write them).

	# Zero the rained flag for this step.
	var stats_zero: PackedByteArray = PackedByteArray()
	stats_zero.resize(4)
	_rd.buffer_update(_buf_stats, 0, 4, stats_zero)

	var groups: int = _groups()
	var cl: int = _rd.compute_list_begin()

	# Three transport passes (independent buffers — no barrier needed between them).
	_rd.compute_list_bind_compute_pipeline(cl, _transport_pipeline)
	_dispatch_transport(cl, _transport_set_vapor, AtmoScript.VAPOR_DIFFUSE, 1.0, wind, groups)
	_dispatch_transport(cl, _transport_set_cloud, AtmoScript.CLOUD_DIFFUSE, 1.0, wind, groups)
	_dispatch_transport(cl, _transport_set_fog, AtmoScript.CLOUD_DIFFUSE * 0.5, 0.5, wind, groups)

	# Condense reads the transport outputs — barrier so the writes are visible.
	_rd.compute_list_add_barrier(cl)
	_rd.compute_list_bind_compute_pipeline(cl, _condense_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _condense_set, 0)
	var cpc: PackedByteArray = PackedByteArray()
	cpc.resize(16)
	cpc.encode_float(0, f.EVAP_TEMP_REF)
	cpc.encode_u32(4, _cell_count)
	cpc.encode_u32(8, 0)
	cpc.encode_u32(12, 0)
	_rd.compute_list_set_push_constant(cl, cpc, cpc.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)

	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	f._vapor = download(_buf_vapor)
	f._cloud = download(_buf_cloud)
	f._fog = download(_buf_fog)
	f._mats[Mat.WATER] = download(_buf_water)

	# Cover means (the CPU reduction the kernel skipped) + the render-dirty flag.
	_apply_cover_means()
	var stats_bytes: PackedByteArray = _rd.buffer_get_data(_buf_stats)
	if stats_bytes.size() >= 4 and stats_bytes.decode_u32(0) != 0:
		f._liquid_dirty = true


## Bind the given transport set + push constant (diffuse fraction, precomputed wind advection) and
## dispatch. ax/az/sx/sz fold in wind_gain, STEP_DT, cell_size and the wind vector exactly as the CPU.
func _dispatch_transport(cl: int, uset: RID, diffuse_frac: float, wind_gain: float, wind: Vector2, groups: int) -> void:
	var f = _field
	var ax: float = clampf(absf(wind.x) * wind_gain * f.STEP_DT / f._cell_size, 0.0, 0.5)
	var az: float = clampf(absf(wind.y) * wind_gain * f.STEP_DT / f._cell_size, 0.0, 0.5)
	var sx: int = 1 if wind.x > 0.0 else -1
	var sz: int = 1 if wind.y > 0.0 else -1
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_float(0, diffuse_frac)
	pc.encode_float(4, ax)
	pc.encode_float(8, az)
	pc.encode_s32(12, sx)
	pc.encode_s32(16, sz)
	pc.encode_u32(20, _field._dim)
	pc.encode_u32(24, _cell_count)
	pc.encode_u32(28, 0)
	_rd.compute_list_bind_uniform_set(cl, uset, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)


## Mean cloud / fog density over sampled cells (drives sun dimming + HUD). Mirrors the CPU reduction in
## MaterialAtmosphere.step(); writes the cached covers back onto the atmosphere module.
func _apply_cover_means() -> void:
	var f = _field
	var cloud_sum: float = 0.0
	var fog_sum: float = 0.0
	for idx in range(_cell_count):
		if f._sampled[idx] != 0:
			cloud_sum += f._cloud[idx]
			fog_sum += f._fog[idx]
	var denom: float = maxf(1.0, float(f._sampled_count))
	if f._atmosphere != null:
		f._atmosphere._cloud_cover = cloud_sum / denom
		f._atmosphere._fog_cover = fog_sum / denom


func _groups() -> int:
	return int(ceil(float(_cell_count) / float(LOCAL_SIZE_X)))
