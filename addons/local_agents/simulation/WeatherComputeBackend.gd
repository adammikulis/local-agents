extends RefCounted
class_name LocalAgentsWeatherComputeBackend

const SHADER_PATH := "res://addons/local_agents/scenes/simulation/shaders/WeatherFieldCompute.glsl"
const WG_SIZE := 64

var _rd: RenderingDevice
var _shader_rid: RID
var _pipeline_rid: RID
var _uniform_set_rid: RID
var _configured: bool = false
var _supported: bool = false
var _count: int = 0

var _buf_base_moisture: RID
var _buf_base_temp: RID
var _buf_water_reliability: RID
var _buf_elevation: RID
var _buf_slope: RID
var _buf_cloud: RID
var _buf_humidity: RID
var _buf_rain: RID
var _buf_wetness: RID
var _buf_fog: RID
var _buf_orographic: RID
var _buf_rain_shadow: RID
var _buf_activity: RID
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

func is_supported() -> bool:
	return _supported

func is_configured() -> bool:
	return _configured and _supported and _uniform_set_rid.is_valid()

func configure(
	base_moisture: PackedFloat32Array,
	base_temp: PackedFloat32Array,
	water_reliability: PackedFloat32Array,
	elevation: PackedFloat32Array,
	slope: PackedFloat32Array,
	cloud: PackedFloat32Array,
	humidity: PackedFloat32Array,
	rain: PackedFloat32Array,
	wetness: PackedFloat32Array,
	fog: PackedFloat32Array,
	orographic: PackedFloat32Array,
	rain_shadow: PackedFloat32Array
) -> bool:
	if not initialize():
		return false
	_count = base_moisture.size()
	if _count <= 0:
		return false
	if base_temp.size() != _count or water_reliability.size() != _count or elevation.size() != _count or slope.size() != _count:
		return false
	if cloud.size() != _count or humidity.size() != _count or rain.size() != _count or wetness.size() != _count or fog.size() != _count or orographic.size() != _count or rain_shadow.size() != _count:
		return false
	_free_buffers()
	_buf_base_moisture = _storage_buffer_from_f32(base_moisture)
	_buf_base_temp = _storage_buffer_from_f32(base_temp)
	_buf_water_reliability = _storage_buffer_from_f32(water_reliability)
	_buf_elevation = _storage_buffer_from_f32(elevation)
	_buf_slope = _storage_buffer_from_f32(slope)
	_buf_cloud = _storage_buffer_from_f32(cloud)
	_buf_humidity = _storage_buffer_from_f32(humidity)
	_buf_rain = _storage_buffer_from_f32(rain)
	_buf_wetness = _storage_buffer_from_f32(wetness)
	_buf_fog = _storage_buffer_from_f32(fog)
	_buf_orographic = _storage_buffer_from_f32(orographic)
	_buf_rain_shadow = _storage_buffer_from_f32(rain_shadow)
	var zeros = PackedFloat32Array()
	zeros.resize(_count)
	_buf_activity = _storage_buffer_from_f32(zeros)
	var params := PackedFloat32Array([0.0, 0.4, 1.0, 1.0, 0.01, 0.24, 0.0, 0.0, 0.0, 8.0, 0.0, 0.0])
	_buf_params = _storage_buffer_from_f32(params)
	var uniforms: Array[RDUniform] = []
	uniforms.append(_ssbo_uniform(0, _buf_base_moisture))
	uniforms.append(_ssbo_uniform(1, _buf_base_temp))
	uniforms.append(_ssbo_uniform(2, _buf_water_reliability))
	uniforms.append(_ssbo_uniform(3, _buf_elevation))
	uniforms.append(_ssbo_uniform(4, _buf_slope))
	uniforms.append(_ssbo_uniform(5, _buf_cloud))
	uniforms.append(_ssbo_uniform(6, _buf_humidity))
	uniforms.append(_ssbo_uniform(7, _buf_rain))
	uniforms.append(_ssbo_uniform(8, _buf_wetness))
	uniforms.append(_ssbo_uniform(9, _buf_fog))
	uniforms.append(_ssbo_uniform(10, _buf_orographic))
	uniforms.append(_ssbo_uniform(11, _buf_rain_shadow))
	uniforms.append(_ssbo_uniform(12, _buf_activity))
	uniforms.append(_ssbo_uniform(13, _buf_params))
	_uniform_set_rid = _rd.uniform_set_create(uniforms, _shader_rid, 0)
	_configured = _uniform_set_rid.is_valid()
	return _configured

func step(delta: float, wind_speed: float, activity: PackedFloat32Array, tick: int, idle_cadence: int, seed_jitter: float = 0.0) -> Dictionary:
	if not is_configured():
		return {}
	if activity.size() != _count:
		return {}
	_rd.buffer_update(_buf_activity, 0, activity.to_byte_array().size(), activity.to_byte_array())
	var params := PackedFloat32Array([
		maxf(0.0001, delta),
		clampf(wind_speed, 0.05, 2.0),
		1.0,
		1.0,
		0.01 + clampf(wind_speed, 0.05, 2.0) * 0.015,
		0.24,
		seed_jitter,
		float(tick),
		float(maxi(1, idle_cadence)),
		seed_jitter * 997.0,
		0.0,
	])
	_rd.buffer_update(_buf_params, 0, params.to_byte_array().size(), params.to_byte_array())
	var list_id = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list_id, _pipeline_rid)
	_rd.compute_list_bind_uniform_set(list_id, _uniform_set_rid, 0)
	var groups = int(ceil(float(_count) / float(WG_SIZE)))
	_rd.compute_list_dispatch(list_id, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	var cloud = _rd.buffer_get_data(_buf_cloud).to_float32_array()
	var humidity = _rd.buffer_get_data(_buf_humidity).to_float32_array()
	var rain = _rd.buffer_get_data(_buf_rain).to_float32_array()
	var wetness = _rd.buffer_get_data(_buf_wetness).to_float32_array()
	var fog = _rd.buffer_get_data(_buf_fog).to_float32_array()
	var orographic = _rd.buffer_get_data(_buf_orographic).to_float32_array()
	var rain_shadow = _rd.buffer_get_data(_buf_rain_shadow).to_float32_array()
	return {
		"cloud": cloud,
		"humidity": humidity,
		"rain": rain,
		"wetness": wetness,
		"fog": fog,
		"orographic": orographic,
		"rain_shadow": rain_shadow,
	}

func upload_dynamic(
	cloud: PackedFloat32Array,
	humidity: PackedFloat32Array,
	rain: PackedFloat32Array,
	wetness: PackedFloat32Array,
	fog: PackedFloat32Array,
	orographic: PackedFloat32Array,
	rain_shadow: PackedFloat32Array
) -> void:
	if not is_configured():
		return
	if cloud.size() != _count or humidity.size() != _count or rain.size() != _count or wetness.size() != _count or fog.size() != _count:
		return
	_rd.buffer_update(_buf_cloud, 0, cloud.to_byte_array().size(), cloud.to_byte_array())
	_rd.buffer_update(_buf_humidity, 0, humidity.to_byte_array().size(), humidity.to_byte_array())
	_rd.buffer_update(_buf_rain, 0, rain.to_byte_array().size(), rain.to_byte_array())
	_rd.buffer_update(_buf_wetness, 0, wetness.to_byte_array().size(), wetness.to_byte_array())
	_rd.buffer_update(_buf_fog, 0, fog.to_byte_array().size(), fog.to_byte_array())
	if orographic.size() == _count:
		_rd.buffer_update(_buf_orographic, 0, orographic.to_byte_array().size(), orographic.to_byte_array())
	if rain_shadow.size() == _count:
		_rd.buffer_update(_buf_rain_shadow, 0, rain_shadow.to_byte_array().size(), rain_shadow.to_byte_array())

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

func _free_buffers() -> void:
	if _rd == null:
		return
	for rid in [_buf_base_moisture, _buf_base_temp, _buf_water_reliability, _buf_elevation, _buf_slope, _buf_cloud, _buf_humidity, _buf_rain, _buf_wetness, _buf_fog, _buf_orographic, _buf_rain_shadow, _buf_activity, _buf_params]:
		if rid.is_valid():
			_rd.free_rid(rid)
	if _uniform_set_rid.is_valid():
		_rd.free_rid(_uniform_set_rid)
	_uniform_set_rid = RID()
	_buf_base_moisture = RID()
	_buf_base_temp = RID()
	_buf_water_reliability = RID()
	_buf_elevation = RID()
	_buf_slope = RID()
	_buf_cloud = RID()
	_buf_humidity = RID()
	_buf_rain = RID()
	_buf_wetness = RID()
	_buf_fog = RID()
	_buf_orographic = RID()
	_buf_rain_shadow = RID()
	_buf_activity = RID()
	_buf_params = RID()

func _storage_buffer_from_f32(data: PackedFloat32Array) -> RID:
	var bytes = data.to_byte_array()
	return _rd.storage_buffer_create(bytes.size(), bytes)

func _ssbo_uniform(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(rid)
	return u
