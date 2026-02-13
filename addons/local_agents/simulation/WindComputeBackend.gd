extends RefCounted
class_name LocalAgentsWindComputeBackend

const SHADER_PATH := "res://addons/local_agents/scenes/simulation/shaders/WindFieldCompute.glsl"
const WG_SIZE := 64

var _rd: RenderingDevice
var _shader_rid: RID
var _pipeline_rid: RID
var _uniform_set_rid: RID
var _configured: bool = false
var _supported: bool = false
var _count: int = 0

var _buf_temp_read: RID
var _buf_temp_write: RID
var _buf_wind_x_read: RID
var _buf_wind_z_read: RID
var _buf_wind_x_write: RID
var _buf_wind_z_write: RID
var _buf_params: RID

func initialize() -> bool:
	if _supported:
		return true
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		return false
	var shader_file: RDShaderFile = load(SHADER_PATH)
	if shader_file == null:
		return false
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	if shader_spirv == null:
		return false
	_shader_rid = _rd.shader_create_from_spirv(shader_spirv)
	if not _shader_rid.is_valid():
		return false
	_pipeline_rid = _rd.compute_pipeline_create(_shader_rid)
	if not _pipeline_rid.is_valid():
		return false
	_supported = true
	return true

func configure(
	half_extent: float,
	voxel_size: float,
	vertical_half_extent: float,
	terrain_seed: float,
	radius_cells: int,
	vertical_cells: int,
	temperature: PackedFloat32Array,
	wind_x: PackedFloat32Array,
	wind_z: PackedFloat32Array
) -> bool:
	if not initialize():
		return false
	_count = temperature.size()
	if _count <= 0:
		return false
	if wind_x.size() != _count or wind_z.size() != _count:
		return false
	if radius_cells <= 0 or vertical_cells <= 0:
		return false
	_free_buffers()
	_buf_temp_read = _storage_buffer_from_f32(temperature)
	_buf_temp_write = _storage_buffer_from_f32(temperature)
	_buf_wind_x_read = _storage_buffer_from_f32(wind_x)
	_buf_wind_z_read = _storage_buffer_from_f32(wind_z)
	_buf_wind_x_write = _storage_buffer_from_f32(wind_x)
	_buf_wind_z_write = _storage_buffer_from_f32(wind_z)
	_buf_params = _storage_buffer_from_f32(
		PackedFloat32Array([
			1.0,
			0.5,
			0.0,
			0.0,
			0.0,
			0.0,
			0.0,
			0.0,
			1.0,
			maxf(0.1, voxel_size),
			maxf(voxel_size, vertical_half_extent),
			maxf(voxel_size, half_extent),
			1.0,
			0.0,
			0.0,
			1.0,
			float(radius_cells),
			float(vertical_cells),
			0.0,
			terrain_seed,
		])
	)
	_configured = _buf_temp_read.is_valid() and _buf_temp_write.is_valid() and _buf_wind_x_read.is_valid() and _buf_wind_z_read.is_valid() and _buf_wind_x_write.is_valid() and _buf_wind_z_write.is_valid() and _buf_params.is_valid()
	return _configured

func is_configured() -> bool:
	return _configured and _supported and _count > 0 and _pipeline_rid.is_valid()

func step(
	delta: float,
	ambient_temp: float,
	diurnal_phase: float,
	rain_intensity: float,
	sun_altitude: float,
	avg_insolation: float,
	avg_uv_index: float,
	avg_heat_load: float,
	air_heating_scalar: float,
	base_direction: Vector2,
	base_intensity: float,
	base_speed: float,
	half_extent: float,
	voxel_size: float,
	vertical_half_extent: float,
	radius_cells: int,
	vertical_cells: int,
	terrain_seed: float
) -> Dictionary:
	if not is_configured():
		return {}
	var params = PackedFloat32Array([
		maxf(0.0001, delta),
		clampf(ambient_temp, 0.0, 1.2),
		diurnal_phase,
		clampf(rain_intensity, 0.0, 1.0),
		clampf(sun_altitude, 0.0, 1.0),
		clampf(avg_insolation, 0.0, 1.0),
		clampf(avg_uv_index, 0.0, 2.0),
		clampf(avg_heat_load, 0.0, 1.5),
		clampf(air_heating_scalar, 0.2, 2.0),
		maxf(0.1, voxel_size),
		maxf(voxel_size, vertical_half_extent),
		maxf(voxel_size, half_extent),
		base_direction.x,
		base_direction.y,
		clampf(base_intensity, 0.0, 1.0),
		maxf(0.0, base_speed),
		float(maxi(1, radius_cells)),
		float(maxi(1, vertical_cells)),
		0.0,
		terrain_seed,
	])
	if not _dispatch_pass(params, 0.0):
		return {}
	_swap_temp_buffers()
	if not _dispatch_pass(params, 1.0):
		return {}
	_swap_wind_buffers()
	_rd.submit()
	_rd.sync()
	return {
		"temperature": _rd.buffer_get_data(_buf_temp_read).to_float32_array(),
		"wind_x": _rd.buffer_get_data(_buf_wind_x_read).to_float32_array(),
		"wind_z": _rd.buffer_get_data(_buf_wind_z_read).to_float32_array(),
	}

func release() -> void:
	_free_buffers()
	if _rd != null:
		if _uniform_set_rid.is_valid():
			_rd.free_rid(_uniform_set_rid)
		if _pipeline_rid.is_valid():
			_rd.free_rid(_pipeline_rid)
		if _shader_rid.is_valid():
			_rd.free_rid(_shader_rid)
	_configured = false
	_supported = false
	_count = 0

func _dispatch_pass(base_params: PackedFloat32Array, phase: float) -> bool:
	if _rd == null:
		return false
	var params = base_params
	params[18] = phase
	var bytes = params.to_byte_array()
	_rd.buffer_update(_buf_params, 0, bytes.size(), bytes)
	if _uniform_set_rid.is_valid():
		_rd.free_rid(_uniform_set_rid)
	_uniform_set_rid = RID()
	var uniforms: Array[RDUniform] = []
	uniforms.append(_ssbo_uniform(0, _buf_temp_read))
	uniforms.append(_ssbo_uniform(1, _buf_temp_write))
	uniforms.append(_ssbo_uniform(2, _buf_wind_x_read))
	uniforms.append(_ssbo_uniform(3, _buf_wind_z_read))
	uniforms.append(_ssbo_uniform(4, _buf_wind_x_write))
	uniforms.append(_ssbo_uniform(5, _buf_wind_z_write))
	uniforms.append(_ssbo_uniform(6, _buf_params))
	_uniform_set_rid = _rd.uniform_set_create(uniforms, _shader_rid, 0)
	if not _uniform_set_rid.is_valid():
		return false
	var list_id = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list_id, _pipeline_rid)
	_rd.compute_list_bind_uniform_set(list_id, _uniform_set_rid, 0)
	var groups = int(ceil(float(_count) / float(WG_SIZE)))
	_rd.compute_list_dispatch(list_id, groups, 1, 1)
	_rd.compute_list_end()
	return true

func _swap_temp_buffers() -> void:
	var next = _buf_temp_read
	_buf_temp_read = _buf_temp_write
	_buf_temp_write = next

func _swap_wind_buffers() -> void:
	var next_x = _buf_wind_x_read
	var next_z = _buf_wind_z_read
	_buf_wind_x_read = _buf_wind_x_write
	_buf_wind_z_read = _buf_wind_z_write
	_buf_wind_x_write = next_x
	_buf_wind_z_write = next_z

func _free_buffers() -> void:
	if _rd == null:
		return
	for rid in [_buf_temp_read, _buf_temp_write, _buf_wind_x_read, _buf_wind_z_read, _buf_wind_x_write, _buf_wind_z_write, _buf_params]:
		if rid.is_valid():
			_rd.free_rid(rid)
	if _uniform_set_rid.is_valid():
		_rd.free_rid(_uniform_set_rid)
	_uniform_set_rid = RID()
	_buf_temp_read = RID()
	_buf_temp_write = RID()
	_buf_wind_x_read = RID()
	_buf_wind_z_read = RID()
	_buf_wind_x_write = RID()
	_buf_wind_z_write = RID()
	_buf_params = RID()

func _storage_buffer_from_f32(data: PackedFloat32Array) -> RID:
	var bytes = data.to_byte_array()
	return _rd.storage_buffer_create(bytes.size(), bytes)

func _ssbo_uniform(binding: int, rid: RID) -> RDUniform:
	var out := RDUniform.new()
	out.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	out.binding = binding
	out.add_id(rid)
	return out
