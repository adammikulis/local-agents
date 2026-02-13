extends RefCounted
class_name LocalAgentsErosionComputeBackend

const SHADER_PATH := "res://addons/local_agents/scenes/simulation/shaders/ErosionFieldCompute.glsl"
const WG_SIZE := 64

var _rd: RenderingDevice
var _shader_rid: RID
var _pipeline_rid: RID
var _uniform_set_rid: RID
var _configured: bool = false
var _supported: bool = false
var _count: int = 0

var _buf_slope: RID
var _buf_temp_base: RID
var _buf_rain: RID
var _buf_cloud: RID
var _buf_wetness: RID
var _buf_flow_norm: RID
var _buf_water_rel: RID
var _buf_activity: RID
var _buf_erosion_budget: RID
var _buf_frost_damage: RID
var _buf_temp_prev: RID
var _buf_elev_drop: RID
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

func configure(slope: PackedFloat32Array, temp_base: PackedFloat32Array, activity: PackedFloat32Array, erosion_budget: PackedFloat32Array, frost_damage: PackedFloat32Array, temp_prev: PackedFloat32Array) -> bool:
	if not initialize():
		return false
	_count = slope.size()
	if _count <= 0:
		return false
	if temp_base.size() != _count or activity.size() != _count or erosion_budget.size() != _count or frost_damage.size() != _count or temp_prev.size() != _count:
		return false
	_free_buffers()
	_buf_slope = _storage_buffer_from_f32(slope)
	_buf_temp_base = _storage_buffer_from_f32(temp_base)
	var zeros = PackedFloat32Array()
	zeros.resize(_count)
	_buf_rain = _storage_buffer_from_f32(zeros)
	_buf_cloud = _storage_buffer_from_f32(zeros)
	_buf_wetness = _storage_buffer_from_f32(zeros)
	_buf_flow_norm = _storage_buffer_from_f32(zeros)
	_buf_water_rel = _storage_buffer_from_f32(zeros)
	_buf_activity = _storage_buffer_from_f32(activity)
	_buf_erosion_budget = _storage_buffer_from_f32(erosion_budget)
	_buf_frost_damage = _storage_buffer_from_f32(frost_damage)
	_buf_temp_prev = _storage_buffer_from_f32(temp_prev)
	_buf_elev_drop = _storage_buffer_from_f32(zeros)
	var params = PackedFloat32Array([0.0, 1.0, 0.34, 0.0, 8.0])
	_buf_params = _storage_buffer_from_f32(params)
	var uniforms: Array[RDUniform] = []
	uniforms.append(_ssbo_uniform(0, _buf_slope))
	uniforms.append(_ssbo_uniform(1, _buf_temp_base))
	uniforms.append(_ssbo_uniform(2, _buf_rain))
	uniforms.append(_ssbo_uniform(3, _buf_cloud))
	uniforms.append(_ssbo_uniform(4, _buf_wetness))
	uniforms.append(_ssbo_uniform(5, _buf_flow_norm))
	uniforms.append(_ssbo_uniform(6, _buf_water_rel))
	uniforms.append(_ssbo_uniform(7, _buf_activity))
	uniforms.append(_ssbo_uniform(8, _buf_erosion_budget))
	uniforms.append(_ssbo_uniform(9, _buf_frost_damage))
	uniforms.append(_ssbo_uniform(10, _buf_temp_prev))
	uniforms.append(_ssbo_uniform(11, _buf_elev_drop))
	uniforms.append(_ssbo_uniform(12, _buf_params))
	_uniform_set_rid = _rd.uniform_set_create(uniforms, _shader_rid, 0)
	_configured = _uniform_set_rid.is_valid()
	return _configured

func is_configured() -> bool:
	return _configured and _supported and _uniform_set_rid.is_valid()

func step(rain: PackedFloat32Array, cloud: PackedFloat32Array, wetness: PackedFloat32Array, flow_norm: PackedFloat32Array, water_rel: PackedFloat32Array, activity: PackedFloat32Array, tick: int, delta: float, seed_jitter: float, idle_cadence: int) -> Dictionary:
	if not is_configured():
		return {}
	if rain.size() != _count or cloud.size() != _count or wetness.size() != _count or flow_norm.size() != _count or water_rel.size() != _count or activity.size() != _count:
		return {}
	_rd.buffer_update(_buf_rain, 0, rain.to_byte_array().size(), rain.to_byte_array())
	_rd.buffer_update(_buf_cloud, 0, cloud.to_byte_array().size(), cloud.to_byte_array())
	_rd.buffer_update(_buf_wetness, 0, wetness.to_byte_array().size(), wetness.to_byte_array())
	_rd.buffer_update(_buf_flow_norm, 0, flow_norm.to_byte_array().size(), flow_norm.to_byte_array())
	_rd.buffer_update(_buf_water_rel, 0, water_rel.to_byte_array().size(), water_rel.to_byte_array())
	_rd.buffer_update(_buf_activity, 0, activity.to_byte_array().size(), activity.to_byte_array())
	var params = PackedFloat32Array([float(tick), clampf(delta, 0.1, 2.0), 0.34, seed_jitter, float(maxi(1, idle_cadence))])
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
		"erosion_budget": _rd.buffer_get_data(_buf_erosion_budget).to_float32_array(),
		"frost_damage": _rd.buffer_get_data(_buf_frost_damage).to_float32_array(),
		"temp_prev": _rd.buffer_get_data(_buf_temp_prev).to_float32_array(),
		"elev_drop": _rd.buffer_get_data(_buf_elev_drop).to_float32_array(),
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

func _free_buffers() -> void:
	if _rd == null:
		return
	for rid in [_buf_slope, _buf_temp_base, _buf_rain, _buf_cloud, _buf_wetness, _buf_flow_norm, _buf_water_rel, _buf_activity, _buf_erosion_budget, _buf_frost_damage, _buf_temp_prev, _buf_elev_drop, _buf_params]:
		if rid.is_valid():
			_rd.free_rid(rid)
	if _uniform_set_rid.is_valid():
		_rd.free_rid(_uniform_set_rid)
	_uniform_set_rid = RID()
	_buf_slope = RID()
	_buf_temp_base = RID()
	_buf_rain = RID()
	_buf_cloud = RID()
	_buf_wetness = RID()
	_buf_flow_norm = RID()
	_buf_water_rel = RID()
	_buf_activity = RID()
	_buf_erosion_budget = RID()
	_buf_frost_damage = RID()
	_buf_temp_prev = RID()
	_buf_elev_drop = RID()
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
