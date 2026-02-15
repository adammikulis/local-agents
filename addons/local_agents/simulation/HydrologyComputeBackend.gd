extends RefCounted
class_name LocalAgentsHydrologyComputeBackend

const SHADER_PATH := "res://addons/local_agents/scenes/simulation/shaders/HydrologyFieldCompute.glsl"
const WG_SIZE := 64

var _rd: RenderingDevice
var _shader_rid: RID
var _pipeline_rid: RID
var _uniform_set_rid: RID
var _configured: bool = false
var _supported: bool = false
var _count: int = 0
var _owned_rids: Array[RID] = []

var _buf_base_moisture: RID
var _buf_base_elevation: RID
var _buf_base_slope: RID
var _buf_base_heat: RID
var _buf_spring_discharge: RID
var _buf_rain: RID
var _buf_wetness: RID
var _buf_activity: RID
var _buf_flow: RID
var _buf_reliability: RID
var _buf_flood_risk: RID
var _buf_water_depth: RID
var _buf_pressure: RID
var _buf_recharge: RID
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
	_shader_rid = _track_rid(_rd.shader_create_from_spirv(shader_spirv))
	if not _shader_rid.is_valid():
		return false
	_pipeline_rid = _track_rid(_rd.compute_pipeline_create(_shader_rid))
	if not _pipeline_rid.is_valid():
		return false
	_supported = true
	return true

func is_configured() -> bool:
	return _configured and _supported and _uniform_set_rid.is_valid()

func configure(
	base_moisture: PackedFloat32Array,
	base_elevation: PackedFloat32Array,
	base_slope: PackedFloat32Array,
	base_heat: PackedFloat32Array,
	spring_discharge: PackedFloat32Array,
	flow: PackedFloat32Array,
	reliability: PackedFloat32Array,
	flood_risk: PackedFloat32Array,
	water_depth: PackedFloat32Array,
	pressure: PackedFloat32Array,
	recharge: PackedFloat32Array
) -> bool:
	if not initialize():
		return false
	_count = base_moisture.size()
	if _count <= 0:
		return false
	if base_elevation.size() != _count or base_slope.size() != _count or base_heat.size() != _count:
		return false
	if spring_discharge.size() != _count:
		return false
	if flow.size() != _count or reliability.size() != _count or flood_risk.size() != _count or water_depth.size() != _count or pressure.size() != _count or recharge.size() != _count:
		return false
	_free_buffers()
	_buf_base_moisture = _storage_buffer_from_f32(base_moisture)
	_buf_base_elevation = _storage_buffer_from_f32(base_elevation)
	_buf_base_slope = _storage_buffer_from_f32(base_slope)
	_buf_base_heat = _storage_buffer_from_f32(base_heat)
	_buf_spring_discharge = _storage_buffer_from_f32(spring_discharge)
	_buf_rain = _storage_buffer_from_f32(_zeros(_count))
	_buf_wetness = _storage_buffer_from_f32(_zeros(_count))
	_buf_activity = _storage_buffer_from_f32(_zeros(_count))
	_buf_flow = _storage_buffer_from_f32(flow)
	_buf_reliability = _storage_buffer_from_f32(reliability)
	_buf_flood_risk = _storage_buffer_from_f32(flood_risk)
	_buf_water_depth = _storage_buffer_from_f32(water_depth)
	_buf_pressure = _storage_buffer_from_f32(pressure)
	_buf_recharge = _storage_buffer_from_f32(recharge)
	_buf_params = _storage_buffer_from_f32(PackedFloat32Array([1.0, 0.0, 8.0, 0.0, float(_count)]))
	var uniforms: Array[RDUniform] = []
	uniforms.append(_ssbo_uniform(0, _buf_base_moisture))
	uniforms.append(_ssbo_uniform(1, _buf_base_elevation))
	uniforms.append(_ssbo_uniform(2, _buf_base_slope))
	uniforms.append(_ssbo_uniform(3, _buf_base_heat))
	uniforms.append(_ssbo_uniform(4, _buf_spring_discharge))
	uniforms.append(_ssbo_uniform(5, _buf_rain))
	uniforms.append(_ssbo_uniform(6, _buf_wetness))
	uniforms.append(_ssbo_uniform(7, _buf_activity))
	uniforms.append(_ssbo_uniform(8, _buf_flow))
	uniforms.append(_ssbo_uniform(9, _buf_reliability))
	uniforms.append(_ssbo_uniform(10, _buf_flood_risk))
	uniforms.append(_ssbo_uniform(11, _buf_water_depth))
	uniforms.append(_ssbo_uniform(12, _buf_pressure))
	uniforms.append(_ssbo_uniform(13, _buf_recharge))
	uniforms.append(_ssbo_uniform(14, _buf_params))
	_uniform_set_rid = _track_rid(_rd.uniform_set_create(uniforms, _shader_rid, 0))
	_configured = _uniform_set_rid.is_valid()
	return _configured

func step(
	delta: float,
	tick: int,
	idle_cadence: int,
	seed: int,
	rain: PackedFloat32Array,
	wetness: PackedFloat32Array,
	activity: PackedFloat32Array
) -> Dictionary:
	if not is_configured():
		return {}
	if rain.size() != _count or wetness.size() != _count or activity.size() != _count:
		return {}
	var rain_bytes = rain.to_byte_array()
	var wet_bytes = wetness.to_byte_array()
	var activity_bytes = activity.to_byte_array()
	_rd.buffer_update(_buf_rain, 0, rain_bytes.size(), rain_bytes)
	_rd.buffer_update(_buf_wetness, 0, wet_bytes.size(), wet_bytes)
	_rd.buffer_update(_buf_activity, 0, activity_bytes.size(), activity_bytes)
	var params = PackedFloat32Array([maxf(0.0001, delta), float(tick), float(maxi(1, idle_cadence)), float(abs(seed % 8192)), float(_count)])
	var params_bytes = params.to_byte_array()
	_rd.buffer_update(_buf_params, 0, params_bytes.size(), params_bytes)
	var list_id = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list_id, _pipeline_rid)
	_rd.compute_list_bind_uniform_set(list_id, _uniform_set_rid, 0)
	var groups = int(ceil(float(_count) / float(WG_SIZE)))
	_rd.compute_list_dispatch(list_id, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	return {
		"flow": _rd.buffer_get_data(_buf_flow).to_float32_array(),
		"water_reliability": _rd.buffer_get_data(_buf_reliability).to_float32_array(),
		"flood_risk": _rd.buffer_get_data(_buf_flood_risk).to_float32_array(),
		"water_table_depth": _rd.buffer_get_data(_buf_water_depth).to_float32_array(),
		"hydraulic_pressure": _rd.buffer_get_data(_buf_pressure).to_float32_array(),
		"groundwater_recharge": _rd.buffer_get_data(_buf_recharge).to_float32_array(),
	}

func release() -> void:
	_free_buffers()
	_pipeline_rid = _release_rid(_pipeline_rid)
	_shader_rid = _release_rid(_shader_rid)
	_owned_rids.clear()
	_rd = null
	_configured = false
	_supported = false
	_count = 0

func _zeros(count: int) -> PackedFloat32Array:
	var arr := PackedFloat32Array()
	arr.resize(count)
	return arr

func _free_buffers() -> void:
	if _rd == null:
		_reset_buffer_rids()
		return
	if _uniform_set_rid.is_valid():
		_uniform_set_rid = _release_rid(_uniform_set_rid)
	_buf_base_moisture = _release_rid(_buf_base_moisture)
	_buf_base_elevation = _release_rid(_buf_base_elevation)
	_buf_base_slope = _release_rid(_buf_base_slope)
	_buf_base_heat = _release_rid(_buf_base_heat)
	_buf_spring_discharge = _release_rid(_buf_spring_discharge)
	_buf_rain = _release_rid(_buf_rain)
	_buf_wetness = _release_rid(_buf_wetness)
	_buf_activity = _release_rid(_buf_activity)
	_buf_flow = _release_rid(_buf_flow)
	_buf_reliability = _release_rid(_buf_reliability)
	_buf_flood_risk = _release_rid(_buf_flood_risk)
	_buf_water_depth = _release_rid(_buf_water_depth)
	_buf_pressure = _release_rid(_buf_pressure)
	_buf_recharge = _release_rid(_buf_recharge)
	_buf_params = _release_rid(_buf_params)
	_configured = false

func _reset_buffer_rids() -> void:
	_buf_base_moisture = RID()
	_buf_base_elevation = RID()
	_buf_base_slope = RID()
	_buf_base_heat = RID()
	_buf_spring_discharge = RID()
	_buf_rain = RID()
	_buf_wetness = RID()
	_buf_activity = RID()
	_buf_flow = RID()
	_buf_reliability = RID()
	_buf_flood_risk = RID()
	_buf_water_depth = RID()
	_buf_pressure = RID()
	_buf_recharge = RID()
	_buf_params = RID()
	_uniform_set_rid = RID()

func _release_rid(rid: RID) -> RID:
	if _rd == null or not rid.is_valid():
		return RID()
	if not _owned_rids.has(rid):
		return RID()
	var owned = false
	for i in range(_owned_rids.size() - 1, -1, -1):
		if _owned_rids[i] == rid:
			_owned_rids.remove_at(i)
			owned = true
	_rd.free_rid(rid)
	return RID() if owned else RID()

func _storage_buffer_from_f32(data: PackedFloat32Array) -> RID:
	var bytes = data.to_byte_array()
	var rid = _rd.storage_buffer_create(bytes.size(), bytes)
	if rid.is_valid() and not _owned_rids.has(rid):
		_owned_rids.append(rid)
	return rid

func _track_rid(rid: RID) -> RID:
	if rid.is_valid() and not _owned_rids.has(rid):
		_owned_rids.append(rid)
	return rid

func _ssbo_uniform(binding: int, rid: RID) -> RDUniform:
	var out := RDUniform.new()
	out.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	out.binding = binding
	out.add_id(rid)
	return out
