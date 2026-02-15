extends RefCounted
class_name LocalAgentsSolarComputeBackend

const SHADER_PATH := "res://addons/local_agents/scenes/simulation/shaders/SolarFieldCompute.glsl"
const WG_SIZE := 64

var _rd: RenderingDevice
var _shader_rid: RID
var _pipeline_rid: RID
var _uniform_set_rid: RID
var _configured: bool = false
var _supported: bool = false
var _count: int = 0

var _buf_elevation: RID
var _buf_moisture: RID
var _buf_temperature: RID
var _buf_shade: RID
var _buf_aspect_x: RID
var _buf_aspect_y: RID
var _buf_albedo: RID
var _buf_weather_cloud: RID
var _buf_weather_fog: RID
var _buf_weather_humidity: RID
var _buf_activity: RID
var _buf_sunlight: RID
var _buf_uv: RID
var _buf_heat: RID
var _buf_growth: RID
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
	elevation: PackedFloat32Array,
	moisture: PackedFloat32Array,
	temperature: PackedFloat32Array,
	shade: PackedFloat32Array,
	aspect_x: PackedFloat32Array,
	aspect_y: PackedFloat32Array,
	albedo: PackedFloat32Array
) -> bool:
	if not initialize():
		return false
	_count = elevation.size()
	if _count <= 0:
		return false
	if moisture.size() != _count or temperature.size() != _count or shade.size() != _count or aspect_x.size() != _count or aspect_y.size() != _count or albedo.size() != _count:
		return false
	_free_buffers()
	_buf_elevation = _storage_buffer_from_f32(elevation)
	_buf_moisture = _storage_buffer_from_f32(moisture)
	_buf_temperature = _storage_buffer_from_f32(temperature)
	_buf_shade = _storage_buffer_from_f32(shade)
	_buf_aspect_x = _storage_buffer_from_f32(aspect_x)
	_buf_aspect_y = _storage_buffer_from_f32(aspect_y)
	_buf_albedo = _storage_buffer_from_f32(albedo)
	var zeros = PackedFloat32Array()
	zeros.resize(_count)
	_buf_weather_cloud = _storage_buffer_from_f32(zeros)
	_buf_weather_fog = _storage_buffer_from_f32(zeros)
	_buf_weather_humidity = _storage_buffer_from_f32(zeros)
	_buf_activity = _storage_buffer_from_f32(zeros)
	_buf_sunlight = _storage_buffer_from_f32(zeros)
	_buf_uv = _storage_buffer_from_f32(zeros)
	_buf_heat = _storage_buffer_from_f32(zeros)
	_buf_growth = _storage_buffer_from_f32(zeros)
	var params = PackedFloat32Array([1.0, 0.0, 0.0, 8.0, 0.0, 0.0, 0.0, 0.0])
	_buf_params = _storage_buffer_from_f32(params)
	var uniforms: Array[RDUniform] = []
	uniforms.append(_ssbo_uniform(0, _buf_elevation))
	uniforms.append(_ssbo_uniform(1, _buf_moisture))
	uniforms.append(_ssbo_uniform(2, _buf_temperature))
	uniforms.append(_ssbo_uniform(3, _buf_shade))
	uniforms.append(_ssbo_uniform(4, _buf_aspect_x))
	uniforms.append(_ssbo_uniform(5, _buf_aspect_y))
	uniforms.append(_ssbo_uniform(6, _buf_albedo))
	uniforms.append(_ssbo_uniform(7, _buf_weather_cloud))
	uniforms.append(_ssbo_uniform(8, _buf_weather_fog))
	uniforms.append(_ssbo_uniform(9, _buf_weather_humidity))
	uniforms.append(_ssbo_uniform(10, _buf_activity))
	uniforms.append(_ssbo_uniform(11, _buf_sunlight))
	uniforms.append(_ssbo_uniform(12, _buf_uv))
	uniforms.append(_ssbo_uniform(13, _buf_heat))
	uniforms.append(_ssbo_uniform(14, _buf_growth))
	uniforms.append(_ssbo_uniform(15, _buf_params))
	_uniform_set_rid = _rd.uniform_set_create(uniforms, _shader_rid, 0)
	_configured = _uniform_set_rid.is_valid()
	return _configured

func is_configured() -> bool:
	return _configured and _supported and _uniform_set_rid.is_valid()

func step(weather_cloud: PackedFloat32Array, weather_fog: PackedFloat32Array, weather_humidity: PackedFloat32Array, activity: PackedFloat32Array, sun_dir: Vector2, sun_alt: float, tick: int, idle_cadence: int, seed: int) -> Dictionary:
	if not is_configured():
		return {}
	if weather_cloud.size() != _count or weather_fog.size() != _count or weather_humidity.size() != _count or activity.size() != _count:
		return {}
	_rd.buffer_update(_buf_weather_cloud, 0, weather_cloud.to_byte_array().size(), weather_cloud.to_byte_array())
	_rd.buffer_update(_buf_weather_fog, 0, weather_fog.to_byte_array().size(), weather_fog.to_byte_array())
	_rd.buffer_update(_buf_weather_humidity, 0, weather_humidity.to_byte_array().size(), weather_humidity.to_byte_array())
	_rd.buffer_update(_buf_activity, 0, activity.to_byte_array().size(), activity.to_byte_array())
	var params = PackedFloat32Array([sun_dir.x, sun_dir.y, clampf(sun_alt, 0.0, 1.0), float(maxi(1, idle_cadence)), float(tick), float(seed), 0.0, 0.0])
	_rd.buffer_update(_buf_params, 0, params.to_byte_array().size(), params.to_byte_array())
	var list_id = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list_id, _pipeline_rid)
	_rd.compute_list_bind_uniform_set(list_id, _uniform_set_rid, 0)
	var groups = int(ceil(float(_count) / float(WG_SIZE)))
	_rd.compute_list_dispatch(list_id, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	return {
		"sunlight_total": _rd.buffer_get_data(_buf_sunlight).to_float32_array(),
		"uv_index": _rd.buffer_get_data(_buf_uv).to_float32_array(),
		"heat_load": _rd.buffer_get_data(_buf_heat).to_float32_array(),
		"plant_growth_factor": _rd.buffer_get_data(_buf_growth).to_float32_array(),
	}

func release() -> void:
	_free_buffers()
	_pipeline_rid = _release_rid(_pipeline_rid)
	_shader_rid = _release_rid(_shader_rid)
	_configured = false
	_supported = false
	_count = 0

func _free_buffers() -> void:
	_buf_elevation = _release_rid(_buf_elevation)
	_buf_moisture = _release_rid(_buf_moisture)
	_buf_temperature = _release_rid(_buf_temperature)
	_buf_shade = _release_rid(_buf_shade)
	_buf_aspect_x = _release_rid(_buf_aspect_x)
	_buf_aspect_y = _release_rid(_buf_aspect_y)
	_buf_albedo = _release_rid(_buf_albedo)
	_buf_weather_cloud = _release_rid(_buf_weather_cloud)
	_buf_weather_fog = _release_rid(_buf_weather_fog)
	_buf_weather_humidity = _release_rid(_buf_weather_humidity)
	_buf_activity = _release_rid(_buf_activity)
	_buf_sunlight = _release_rid(_buf_sunlight)
	_buf_uv = _release_rid(_buf_uv)
	_buf_heat = _release_rid(_buf_heat)
	_buf_growth = _release_rid(_buf_growth)
	_buf_params = _release_rid(_buf_params)
	_uniform_set_rid = _release_rid(_uniform_set_rid)

func _release_rid(rid: RID) -> RID:
	if _rd == null or not rid.is_valid():
		return RID()
	_rd.free_rid(rid)
	return RID()

func _storage_buffer_from_f32(data: PackedFloat32Array) -> RID:
	var bytes = data.to_byte_array()
	return _rd.storage_buffer_create(bytes.size(), bytes)

func _ssbo_uniform(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(rid)
	return u
