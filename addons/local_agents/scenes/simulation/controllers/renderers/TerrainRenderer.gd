extends RefCounted
class_name LocalAgentsTerrainRenderer

const WaterFlowShader = preload("res://addons/local_agents/scenes/simulation/shaders/VoxelWaterFlow.gdshader")
const TerrainWeatherShader = preload("res://addons/local_agents/scenes/simulation/shaders/VoxelTerrainWeather.gdshader")

var _terrain_root: Node3D
var _mesh_cache: Dictionary = {}
var _material_cache: Dictionary = {}
var _chunk_node_index: Dictionary = {}

var _weather_snapshot: Dictionary = {}
var _water_shader_params := {
	"flow_dir": Vector2(1.0, 0.2),
	"flow_speed": 0.95,
	"noise_scale": 0.48,
	"foam_strength": 0.36,
	"wave_strength": 0.32,
	"rain_intensity": 0.0,
	"cloud_shadow": 0.0,
	"weather_wind_dir": Vector2(1.0, 0.0),
	"weather_wind_speed": 0.5,
	"weather_cloud_scale": 0.045,
	"weather_cloud_strength": 0.55,
	"weather_field_blend": 1.0,
}
var _weather_field_texture: Texture2D
var _weather_field_world_size: Vector2 = Vector2.ONE
var _surface_field_texture: Texture2D
var _solar_field_texture: Texture2D
var _water_render_mode: String = "simple"

var _chunk_build_thread: Thread
var _chunk_build_in_flight: bool = false
var _chunk_build_result: Dictionary = {}
var _chunk_build_request_id: int = 0
var _chunk_build_applied_id: int = 0
var _chunk_build_pending_payload: Dictionary = {}
var _chunk_build_has_pending: bool = false

func configure(terrain_root: Node3D) -> void:
	_terrain_root = terrain_root

func set_water_render_mode(mode: String) -> void:
	var normalized = String(mode).to_lower().strip_edges()
	if normalized != "shader":
		normalized = "simple"
	if _water_render_mode == normalized:
		return
	_water_render_mode = normalized
	if _material_cache.has("water"):
		_material_cache.erase("water")

func set_weather_snapshot(weather_snapshot: Dictionary) -> void:
	_weather_snapshot = weather_snapshot.duplicate(true)

func set_render_context(
	water_shader_params: Dictionary,
	weather_field_texture: Texture2D,
	weather_field_world_size: Vector2,
	surface_field_texture: Texture2D,
	solar_field_texture: Texture2D
) -> void:
	for key_variant in water_shader_params.keys():
		_water_shader_params[String(key_variant)] = water_shader_params[key_variant]
	_weather_field_texture = weather_field_texture
	_weather_field_world_size = weather_field_world_size
	_surface_field_texture = surface_field_texture
	_solar_field_texture = solar_field_texture

func clear_generated() -> void:
	if _terrain_root != null:
		for child in _terrain_root.get_children():
			child.queue_free()
	_mesh_cache.clear()
	_material_cache.clear()
	_chunk_node_index.clear()

func request_chunk_rebuild(
	block_rows: Array,
	chunk_keys: Array,
	chunk_size: int,
	chunk_rows_by_chunk: Dictionary = {},
	chunk_rows_chunk_size: int = 0
) -> void:
	if block_rows.is_empty() or _terrain_root == null:
		return
	var normalized_chunk_keys: Array = []
	for key_variant in chunk_keys:
		var key = String(key_variant).strip_edges()
		if key != "":
			normalized_chunk_keys.append(key)
	normalized_chunk_keys.sort()
	var is_partial = not normalized_chunk_keys.is_empty()
	var use_chunk_rows_fast_path = is_partial and not chunk_rows_by_chunk.is_empty() and int(chunk_rows_chunk_size) == maxi(4, chunk_size)
	var payload := {
		"request_id": _chunk_build_request_id + 1,
		"chunk_size": maxi(4, chunk_size),
		"block_rows": [] if use_chunk_rows_fast_path else block_rows.duplicate(true),
		"chunk_rows_by_chunk": chunk_rows_by_chunk.duplicate(true),
		"chunk_rows_chunk_size": int(chunk_rows_chunk_size),
		"partial": is_partial,
		"target_chunk_keys": normalized_chunk_keys,
	}
	_chunk_build_request_id = int(payload.get("request_id", _chunk_build_request_id + 1))
	if _chunk_build_in_flight:
		_chunk_build_pending_payload = payload
		_chunk_build_has_pending = true
		return
	_start_chunk_build(payload)

func poll() -> void:
	if not _chunk_build_in_flight or _chunk_build_thread == null:
		return
	if _chunk_build_thread.is_alive():
		return
	_chunk_build_result = _chunk_build_thread.wait_to_finish()
	_chunk_build_thread = null
	_chunk_build_in_flight = false
	_apply_chunk_build_result(_chunk_build_result)
	_chunk_build_result = {}
	if _chunk_build_has_pending:
		var payload = _chunk_build_pending_payload.duplicate(true)
		_chunk_build_pending_payload = {}
		_chunk_build_has_pending = false
		_start_chunk_build(payload)

func wait_for_build() -> void:
	if _chunk_build_thread == null:
		return
	if _chunk_build_thread.is_alive():
		_chunk_build_result = _chunk_build_thread.wait_to_finish()
	_chunk_build_thread = null
	_chunk_build_in_flight = false

func set_water_shader_params(params: Dictionary) -> void:
	for key_variant in params.keys():
		var key = String(key_variant)
		_water_shader_params[key] = params[key_variant]
	var material = _material_cache.get("water", null)
	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		for key_variant in _water_shader_params.keys():
			var key = String(key_variant)
			shader_material.set_shader_parameter(key, _water_shader_params[key_variant])
		_apply_weather_field_uniforms(shader_material)
		_apply_surface_field_uniforms(shader_material)
		_apply_solar_field_uniforms(shader_material)

func apply_weather_to_materials(rain: float, cloud: float, humidity: float) -> void:
	for block_type_variant in _material_cache.keys():
		var block_type = String(block_type_variant)
		var material = _material_cache[block_type]
		if block_type == "water":
			continue
		if material is ShaderMaterial:
			var shader_material := material as ShaderMaterial
			shader_material.set_shader_parameter("rain_intensity", rain)
			shader_material.set_shader_parameter("cloud_shadow", cloud * 0.85)
			shader_material.set_shader_parameter("humidity", humidity)
			shader_material.set_shader_parameter("weather_wind_dir", _water_shader_params.get("weather_wind_dir", Vector2(1.0, 0.0)))
			shader_material.set_shader_parameter("weather_wind_speed", _water_shader_params.get("weather_wind_speed", 0.5))
			shader_material.set_shader_parameter("weather_cloud_scale", _water_shader_params.get("weather_cloud_scale", 0.045))
			shader_material.set_shader_parameter("weather_cloud_strength", _water_shader_params.get("weather_cloud_strength", 0.55))
			_apply_weather_field_uniforms(shader_material)
			_apply_surface_field_uniforms(shader_material)
			_apply_solar_field_uniforms(shader_material)

func refresh_material_uniforms() -> void:
	for key_variant in _material_cache.keys():
		var material = _material_cache[key_variant]
		if material is ShaderMaterial:
			var shader_material := material as ShaderMaterial
			_apply_weather_field_uniforms(shader_material)
			_apply_surface_field_uniforms(shader_material)
			_apply_solar_field_uniforms(shader_material)

func _start_chunk_build(payload: Dictionary) -> void:
	wait_for_build()
	_chunk_build_result = {}
	_chunk_build_thread = Thread.new()
	_chunk_build_in_flight = true
	_chunk_build_thread.start(Callable(self, "_thread_build_chunk_payload").bind(payload))

func _thread_build_chunk_payload(payload: Dictionary) -> Dictionary:
	var rows: Array = payload.get("block_rows", [])
	var chunk_size = maxi(4, int(payload.get("chunk_size", 12)))
	var chunk_rows_by_chunk: Dictionary = payload.get("chunk_rows_by_chunk", {})
	var chunk_rows_chunk_size = int(payload.get("chunk_rows_chunk_size", 0))
	var partial = bool(payload.get("partial", false))
	var target_chunk_keys: Array = payload.get("target_chunk_keys", [])
	var target_set: Dictionary = {}
	if partial:
		for key_variant in target_chunk_keys:
			var key = String(key_variant).strip_edges()
			if key != "":
				target_set[key] = true
	var chunk_map: Dictionary = {}
	if partial:
		for key_variant in target_set.keys():
			chunk_map[String(key_variant)] = {}
	var source_rows: Array = rows
	if partial and chunk_rows_chunk_size == chunk_size and not chunk_rows_by_chunk.is_empty():
		source_rows = []
		for key_variant in target_set.keys():
			var key = String(key_variant)
			var chunk_rows_variant = chunk_rows_by_chunk.get(key, [])
			if chunk_rows_variant is Array:
				source_rows.append_array((chunk_rows_variant as Array).duplicate(true))
	for row_variant in source_rows:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var block_type = String(row.get("type", "air"))
		if block_type == "air":
			continue
		var x = int(row.get("x", 0))
		var y = int(row.get("y", 0))
		var z = int(row.get("z", 0))
		var cx = int(floor(float(x) / float(chunk_size)))
		var cz = int(floor(float(z) / float(chunk_size)))
		var chunk_key = "%d:%d" % [cx, cz]
		if partial and not target_set.has(chunk_key):
			continue
		var by_type: Dictionary = chunk_map.get(chunk_key, {})
		if not by_type.has(block_type):
			by_type[block_type] = []
		var local_pos = Vector3(float(x - cx * chunk_size) + 0.5, float(y) + 0.5, float(z - cz * chunk_size) + 0.5)
		(by_type[block_type] as Array).append(local_pos)
		chunk_map[chunk_key] = by_type
	var chunks: Array = []
	var keys = chunk_map.keys()
	keys.sort_custom(func(a, b): return String(a) < String(b))
	for key_variant in keys:
		var key = String(key_variant)
		var parts = key.split(":")
		var cx = int(parts[0]) if parts.size() > 0 else 0
		var cz = int(parts[1]) if parts.size() > 1 else 0
		chunks.append({
			"chunk_key": key,
			"chunk_x": cx,
			"chunk_z": cz,
			"chunk_size": chunk_size,
			"by_type": (chunk_map[key] as Dictionary).duplicate(true),
		})
	return {
		"request_id": int(payload.get("request_id", 0)),
		"partial": partial,
		"chunks": chunks,
	}

func _apply_chunk_build_result(result: Dictionary) -> void:
	if result.is_empty() or _terrain_root == null:
		return
	var request_id = int(result.get("request_id", 0))
	if request_id <= _chunk_build_applied_id:
		return
	_chunk_build_applied_id = request_id
	var is_partial = bool(result.get("partial", false))
	if not is_partial:
		for child in _terrain_root.get_children():
			child.queue_free()
		_chunk_node_index.clear()
	var chunks: Array = result.get("chunks", [])
	for chunk_variant in chunks:
		if not (chunk_variant is Dictionary):
			continue
		var chunk = chunk_variant as Dictionary
		var chunk_key = String(chunk.get("chunk_key", ""))
		if chunk_key == "":
			continue
		if _chunk_node_index.has(chunk_key):
			var old_node = _chunk_node_index[chunk_key]
			if old_node is Node and is_instance_valid(old_node):
				(old_node as Node).queue_free()
			_chunk_node_index.erase(chunk_key)
		var by_type: Dictionary = chunk.get("by_type", {})
		if by_type.is_empty():
			continue
		var chunk_node := Node3D.new()
		var cx = int(chunk.get("chunk_x", 0))
		var cz = int(chunk.get("chunk_z", 0))
		var chunk_size = int(chunk.get("chunk_size", 12))
		chunk_node.name = "Chunk_%d_%d" % [cx, cz]
		chunk_node.position = Vector3(float(cx * chunk_size), 0.0, float(cz * chunk_size))
		_terrain_root.add_child(chunk_node)
		_chunk_node_index[chunk_key] = chunk_node
		var block_types = by_type.keys()
		block_types.sort_custom(func(a, b): return String(a) < String(b))
		for type_variant in block_types:
			var block_type = String(type_variant)
			var positions: Array = by_type.get(block_type, [])
			if positions.is_empty():
				continue
			var mm = MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.instance_count = positions.size()
			mm.mesh = _mesh_for_block(block_type)
			for i in range(positions.size()):
				mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, positions[i]))
			var instance := MultiMeshInstance3D.new()
			instance.name = "Terrain_%s" % block_type
			instance.multimesh = mm
			instance.material_override = _material_for_block(block_type)
			chunk_node.add_child(instance)

func _mesh_for_block(block_type: String) -> Mesh:
	if _mesh_cache.has(block_type):
		return _mesh_cache[block_type]
	if block_type == "water":
		var water_mesh := BoxMesh.new()
		water_mesh.size = Vector3(1.0, 0.92, 1.0)
		_mesh_cache[block_type] = water_mesh
		return water_mesh
	var cube := BoxMesh.new()
	cube.size = Vector3.ONE
	_mesh_cache[block_type] = cube
	return cube

func _material_for_block(block_type: String) -> Material:
	if _material_cache.has(block_type):
		return _material_cache[block_type]
	if block_type == "water":
		if _water_render_mode == "simple":
			var simple_water := StandardMaterial3D.new()
			simple_water.albedo_color = Color(0.14, 0.36, 0.68, 0.72)
			simple_water.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			simple_water.roughness = 0.22
			simple_water.metallic = 0.0
			simple_water.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			_material_cache[block_type] = simple_water
			return simple_water
		var water_material := ShaderMaterial.new()
		water_material.shader = WaterFlowShader
		for key_variant in _water_shader_params.keys():
			water_material.set_shader_parameter(String(key_variant), _water_shader_params[key_variant])
		_apply_weather_field_uniforms(water_material)
		_apply_surface_field_uniforms(water_material)
		_apply_solar_field_uniforms(water_material)
		_material_cache[block_type] = water_material
		return water_material
	var terrain_material := ShaderMaterial.new()
	terrain_material.shader = TerrainWeatherShader
	terrain_material.set_shader_parameter("base_color", _block_color(block_type))
	terrain_material.set_shader_parameter("rain_intensity", float(_water_shader_params.get("rain_intensity", 0.0)))
	terrain_material.set_shader_parameter("cloud_shadow", float(_water_shader_params.get("cloud_shadow", 0.0)))
	terrain_material.set_shader_parameter("humidity", clampf(float(_weather_snapshot.get("avg_humidity", 0.0)), 0.0, 1.0))
	terrain_material.set_shader_parameter("weather_wind_dir", _water_shader_params.get("weather_wind_dir", Vector2(1.0, 0.0)))
	terrain_material.set_shader_parameter("weather_wind_speed", _water_shader_params.get("weather_wind_speed", 0.5))
	terrain_material.set_shader_parameter("weather_cloud_scale", _water_shader_params.get("weather_cloud_scale", 0.045))
	terrain_material.set_shader_parameter("weather_cloud_strength", _water_shader_params.get("weather_cloud_strength", 0.55))
	_apply_weather_field_uniforms(terrain_material)
	_apply_surface_field_uniforms(terrain_material)
	_apply_solar_field_uniforms(terrain_material)
	_material_cache[block_type] = terrain_material
	return terrain_material

func _apply_weather_field_uniforms(shader_material: ShaderMaterial) -> void:
	if shader_material == null:
		return
	shader_material.set_shader_parameter("weather_field_tex", _weather_field_texture)
	shader_material.set_shader_parameter("weather_field_world_size", _weather_field_world_size)
	shader_material.set_shader_parameter("weather_field_blend", 1.0)

func _apply_surface_field_uniforms(shader_material: ShaderMaterial) -> void:
	if shader_material == null:
		return
	shader_material.set_shader_parameter("surface_field_tex", _surface_field_texture)
	shader_material.set_shader_parameter("surface_field_world_size", _weather_field_world_size)
	shader_material.set_shader_parameter("surface_field_blend", 1.0)

func _apply_solar_field_uniforms(shader_material: ShaderMaterial) -> void:
	if shader_material == null:
		return
	shader_material.set_shader_parameter("solar_field_tex", _solar_field_texture)
	shader_material.set_shader_parameter("solar_field_world_size", _weather_field_world_size)
	shader_material.set_shader_parameter("solar_field_blend", 1.0)

func _block_color(block_type: String) -> Color:
	match block_type:
		"grass":
			return Color(0.28, 0.63, 0.2, 1.0)
		"dirt":
			return Color(0.46, 0.31, 0.2, 1.0)
		"clay":
			return Color(0.58, 0.48, 0.42, 1.0)
		"sand":
			return Color(0.8, 0.74, 0.51, 1.0)
		"snow":
			return Color(0.9, 0.94, 0.98, 1.0)
		"stone":
			return Color(0.45, 0.45, 0.47, 1.0)
		"gravel":
			return Color(0.52, 0.5, 0.48, 1.0)
		"basalt":
			return Color(0.2, 0.2, 0.22, 1.0)
		"obsidian":
			return Color(0.1, 0.08, 0.14, 1.0)
		"coal_ore":
			return Color(0.22, 0.22, 0.22, 1.0)
		"copper_ore":
			return Color(0.66, 0.43, 0.25, 1.0)
		"iron_ore":
			return Color(0.58, 0.47, 0.35, 1.0)
		"water":
			return Color(0.18, 0.35, 0.76, 0.62)
		_:
			return Color(1.0, 0.0, 1.0, 1.0)
