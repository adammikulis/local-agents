extends Node3D

const WaterFlowShader = preload("res://addons/local_agents/scenes/simulation/shaders/VoxelWaterFlow.gdshader")
const TerrainWeatherShader = preload("res://addons/local_agents/scenes/simulation/shaders/VoxelTerrainWeather.gdshader")
const CloudLayerShader = preload("res://addons/local_agents/scenes/simulation/shaders/VoxelCloudLayer.gdshader")

@onready var terrain_root: Node3D = $TerrainRoot
@onready var water_root: Node3D = $WaterRoot
@export_range(4, 64, 1) var terrain_chunk_size: int = 12
var _generation_snapshot: Dictionary = {}
var _hydrology_snapshot: Dictionary = {}
var _weather_snapshot: Dictionary = {}
var _material_cache: Dictionary = {}
var _mesh_cache: Dictionary = {}
var _weather_field_image: Image
var _weather_field_texture: ImageTexture
var _weather_field_world_size: Vector2 = Vector2.ONE
var _weather_field_cache := PackedInt32Array()
var _weather_field_last_avg_pack: int = -1
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
var _cloud_layer_instance: MeshInstance3D
var _cloud_layer_material: ShaderMaterial
var _chunk_build_thread: Thread
var _chunk_build_in_flight: bool = false
var _chunk_build_result: Dictionary = {}
var _chunk_build_request_id: int = 0
var _chunk_build_applied_id: int = 0
var _chunk_build_pending_payload: Dictionary = {}
var _chunk_build_has_pending: bool = false
var _chunk_node_index: Dictionary = {}

func _process(_delta: float) -> void:
	_poll_chunk_build()

func _exit_tree() -> void:
	_wait_for_chunk_build()

func clear_generated() -> void:
	for child in terrain_root.get_children():
		child.queue_free()
	for child in water_root.get_children():
		child.queue_free()
	_material_cache.clear()
	_mesh_cache.clear()
	_chunk_node_index.clear()

func apply_generation_data(generation: Dictionary, hydrology: Dictionary) -> void:
	_generation_snapshot = generation.duplicate(true)
	_hydrology_snapshot = hydrology.duplicate(true)
	_ensure_weather_field_texture()
	_request_chunk_rebuild([])
	_rebuild_water_sources()
	_ensure_cloud_layer()
	_update_cloud_layer_geometry()
	_update_weather_field_texture(_weather_snapshot)

func apply_generation_delta(generation: Dictionary, hydrology: Dictionary, changed_tiles: Array) -> void:
	_generation_snapshot = generation.duplicate(true)
	_hydrology_snapshot = hydrology.duplicate(true)
	_ensure_weather_field_texture()
	_update_weather_field_texture(_weather_snapshot)
	var chunk_keys = _chunk_keys_for_changed_tiles(changed_tiles)
	if chunk_keys.is_empty():
		_request_chunk_rebuild([])
		_rebuild_water_sources()
		return
	_request_chunk_rebuild(chunk_keys)

func _rebuild_water_sources() -> void:
	for child in water_root.get_children():
		child.queue_free()
	var source_tiles: Array = _hydrology_snapshot.get("source_tiles", [])
	source_tiles.sort()
	for tile_id_variant in source_tiles:
		var marker := Marker3D.new()
		marker.name = "WaterSource_%s" % String(tile_id_variant).replace(":", "_")
		var coords = String(tile_id_variant).split(":")
		if coords.size() == 2:
			marker.position = Vector3(float(coords[0]), 0.1, float(coords[1]))
		water_root.add_child(marker)

func get_generation_snapshot() -> Dictionary:
	return _generation_snapshot.duplicate(true)

func get_hydrology_snapshot() -> Dictionary:
	return _hydrology_snapshot.duplicate(true)

func set_weather_state(weather_snapshot: Dictionary) -> void:
	_weather_snapshot = weather_snapshot.duplicate(true)
	_update_weather_field_texture(_weather_snapshot)
	var rain = clampf(float(_weather_snapshot.get("avg_rain_intensity", 0.0)), 0.0, 1.0)
	var cloud = clampf(float(_weather_snapshot.get("avg_cloud_cover", 0.0)), 0.0, 1.0)
	var humidity = clampf(float(_weather_snapshot.get("avg_humidity", 0.0)), 0.0, 1.0)
	var wind_row: Dictionary = _weather_snapshot.get("wind_dir", {})
	var wind = Vector2(float(wind_row.get("x", 1.0)), float(wind_row.get("y", 0.0)))
	if wind.length_squared() < 0.0001:
		wind = Vector2(1.0, 0.0)
	wind = wind.normalized()
	var wind_speed = clampf(float(_weather_snapshot.get("wind_speed", 0.5)), 0.05, 2.0)
	var cloud_scale = lerpf(0.06, 0.028, cloud)
	var cloud_strength = clampf(0.4 + cloud * 0.5, 0.0, 1.0)
	set_water_shader_params({
		"rain_intensity": rain,
		"cloud_shadow": cloud * 0.85,
		"flow_speed": 0.88 + rain * 0.45,
		"foam_strength": 0.28 + rain * 0.44,
		"wave_strength": 0.24 + rain * 0.5,
		"weather_wind_dir": wind,
		"weather_wind_speed": wind_speed,
		"weather_cloud_scale": cloud_scale,
		"weather_cloud_strength": cloud_strength,
	})
	_apply_weather_to_cached_materials(rain, cloud, humidity)
	_update_cloud_layer_weather(rain, cloud, humidity, wind, wind_speed)

func set_water_shader_params(params: Dictionary) -> void:
	for key_variant in params.keys():
		var key = String(key_variant)
		_water_shader_params[key] = params.get(key_variant)
	var material = _material_cache.get("water", null)
	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		for key_variant in _water_shader_params.keys():
			var key = String(key_variant)
			shader_material.set_shader_parameter(key, _water_shader_params[key_variant])
		_apply_weather_field_uniforms(shader_material)

func _apply_weather_to_cached_materials(rain: float, cloud: float, humidity: float) -> void:
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
			continue
		if not (material is StandardMaterial3D):
			continue
		var std = material as StandardMaterial3D
		var base = _block_color(block_type)
		var wetness = clampf(rain * 0.78 + humidity * 0.22, 0.0, 1.0)
		var shadow = 1.0 - cloud * 0.22
		var wet_darkening = 1.0 - wetness * 0.16
		std.albedo_color = Color(base.r * shadow * wet_darkening, base.g * shadow * wet_darkening, base.b * shadow * wet_darkening, 1.0)
		std.roughness = clampf(0.95 - wetness * 0.58, 0.18, 1.0)
		std.specular = clampf(0.24 + wetness * 0.48, 0.0, 1.0)

func _request_chunk_rebuild(chunk_keys: Array = []) -> void:
	var voxel_world: Dictionary = _generation_snapshot.get("voxel_world", {})
	var block_rows: Array = voxel_world.get("block_rows", [])
	if block_rows.is_empty() or terrain_root == null:
		return
	var normalized_chunk_keys: Array = []
	for key_variant in chunk_keys:
		var key = String(key_variant).strip_edges()
		if key == "":
			continue
		normalized_chunk_keys.append(key)
	normalized_chunk_keys.sort()
	var is_partial = not normalized_chunk_keys.is_empty()
	var payload := {
		"request_id": _chunk_build_request_id + 1,
		"chunk_size": maxi(4, terrain_chunk_size),
		"block_rows": block_rows.duplicate(true),
		"partial": is_partial,
		"target_chunk_keys": normalized_chunk_keys,
	}
	_chunk_build_request_id = int(payload.get("request_id", _chunk_build_request_id + 1))
	if _chunk_build_in_flight:
		_chunk_build_pending_payload = payload
		_chunk_build_has_pending = true
		return
	_start_chunk_build(payload)

func _start_chunk_build(payload: Dictionary) -> void:
	_wait_for_chunk_build()
	_chunk_build_result = {}
	_chunk_build_thread = Thread.new()
	_chunk_build_in_flight = true
	_chunk_build_thread.start(Callable(self, "_thread_build_chunk_payload").bind(payload))

func _thread_build_chunk_payload(payload: Dictionary) -> Dictionary:
	var rows: Array = payload.get("block_rows", [])
	var chunk_size = maxi(4, int(payload.get("chunk_size", terrain_chunk_size)))
	var partial = bool(payload.get("partial", false))
	var target_chunk_keys: Array = payload.get("target_chunk_keys", [])
	var target_set: Dictionary = {}
	if partial:
		for key_variant in target_chunk_keys:
			var key = String(key_variant).strip_edges()
			if key == "":
				continue
			target_set[key] = true
	var chunk_map: Dictionary = {}
	if partial:
		for key_variant in target_set.keys():
			chunk_map[String(key_variant)] = {}
	for row_variant in rows:
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
		var local_pos = Vector3(
			float(x - cx * chunk_size) + 0.5,
			float(y) + 0.5,
			float(z - cz * chunk_size) + 0.5
		)
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
		"chunk_size": chunk_size,
		"partial": partial,
		"chunks": chunks,
	}

func _poll_chunk_build() -> void:
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

func _wait_for_chunk_build() -> void:
	if _chunk_build_thread == null:
		return
	if _chunk_build_thread.is_alive():
		_chunk_build_result = _chunk_build_thread.wait_to_finish()
	_chunk_build_thread = null
	_chunk_build_in_flight = false

func _apply_chunk_build_result(result: Dictionary) -> void:
	if result.is_empty():
		return
	var request_id = int(result.get("request_id", 0))
	if request_id <= _chunk_build_applied_id:
		return
	_chunk_build_applied_id = request_id
	var is_partial = bool(result.get("partial", false))
	if not is_partial:
		for child in terrain_root.get_children():
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
		var chunk_size = int(chunk.get("chunk_size", terrain_chunk_size))
		chunk_node.name = "Chunk_%d_%d" % [cx, cz]
		chunk_node.position = Vector3(float(cx * chunk_size), 0.0, float(cz * chunk_size))
		terrain_root.add_child(chunk_node)
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

func _chunk_key_for_tile(x: int, z: int) -> String:
	var size = maxi(4, terrain_chunk_size)
	var cx = int(floor(float(x) / float(size)))
	var cz = int(floor(float(z) / float(size)))
	return "%d:%d" % [cx, cz]

func _chunk_keys_for_changed_tiles(changed_tiles: Array) -> Array:
	var keys_map: Dictionary = {}
	for tile_variant in changed_tiles:
		var tile_id = String(tile_variant)
		if tile_id == "":
			continue
		var parts = tile_id.split(":")
		if parts.size() != 2:
			continue
		var x = int(parts[0])
		var z = int(parts[1])
		keys_map[_chunk_key_for_tile(x, z)] = true
	var keys = keys_map.keys()
	keys.sort()
	return keys

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
		var water_material := ShaderMaterial.new()
		water_material.shader = WaterFlowShader
		for key_variant in _water_shader_params.keys():
			var key = String(key_variant)
			water_material.set_shader_parameter(key, _water_shader_params[key_variant])
		_apply_weather_field_uniforms(water_material)
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
	_material_cache[block_type] = terrain_material
	return terrain_material

func _ensure_cloud_layer() -> void:
	if _cloud_layer_instance != null and is_instance_valid(_cloud_layer_instance):
		return
	_cloud_layer_instance = MeshInstance3D.new()
	_cloud_layer_instance.name = "CloudLayer"
	_cloud_layer_material = ShaderMaterial.new()
	_cloud_layer_material.shader = CloudLayerShader
	var plane := PlaneMesh.new()
	plane.size = Vector2(256.0, 256.0)
	plane.subdivide_width = 16
	plane.subdivide_depth = 16
	_cloud_layer_instance.mesh = plane
	_cloud_layer_instance.material_override = _cloud_layer_material
	add_child(_cloud_layer_instance)

func _update_cloud_layer_geometry() -> void:
	if _cloud_layer_instance == null or not is_instance_valid(_cloud_layer_instance):
		return
	var width = maxf(8.0, float(_generation_snapshot.get("width", 32)))
	var depth = maxf(8.0, float(_generation_snapshot.get("height", 32)))
	var voxel_world: Dictionary = _generation_snapshot.get("voxel_world", {})
	var world_height = maxf(8.0, float(voxel_world.get("height", 32)))
	var span = maxf(width, depth) * 3.6
	var plane = _cloud_layer_instance.mesh as PlaneMesh
	if plane != null:
		plane.size = Vector2(span, span)
	_cloud_layer_instance.position = Vector3(width * 0.5, world_height + 18.0, depth * 0.5)

func _update_cloud_layer_weather(rain: float, cloud: float, humidity: float, wind: Vector2, wind_speed: float) -> void:
	if _cloud_layer_material == null:
		return
	_cloud_layer_material.set_shader_parameter("cloud_cover", cloud)
	_cloud_layer_material.set_shader_parameter("cloud_density", clampf(0.45 + humidity * 0.42, 0.0, 1.0))
	_cloud_layer_material.set_shader_parameter("rain_intensity", rain)
	_cloud_layer_material.set_shader_parameter("weather_wind_dir", wind)
	_cloud_layer_material.set_shader_parameter("weather_wind_speed", wind_speed)
	_cloud_layer_material.set_shader_parameter("weather_cloud_scale", lerpf(0.032, 0.015, cloud))
	_cloud_layer_material.set_shader_parameter("layer_variation", clampf(0.25 + humidity * 0.5, 0.0, 1.0))
	_apply_weather_field_uniforms(_cloud_layer_material)

func _ensure_weather_field_texture() -> void:
	var width = maxi(1, int(_generation_snapshot.get("width", 1)))
	var height = maxi(1, int(_generation_snapshot.get("height", 1)))
	var needs_recreate = (
		_weather_field_image == null
		or _weather_field_texture == null
		or _weather_field_image.get_width() != width
		or _weather_field_image.get_height() != height
	)
	_weather_field_world_size = Vector2(float(width), float(height))
	if not needs_recreate:
		return
	_weather_field_image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	_weather_field_image.fill(Color(0.0, 0.0, 0.0, 1.0))
	_weather_field_texture = ImageTexture.create_from_image(_weather_field_image)
	_weather_field_cache.resize(width * height)
	for i in range(_weather_field_cache.size()):
		_weather_field_cache[i] = -1
	_weather_field_last_avg_pack = -1

func _update_weather_field_texture(weather_snapshot: Dictionary) -> void:
	_ensure_weather_field_texture()
	if _weather_field_image == null or _weather_field_texture == null:
		return
	var width = _weather_field_image.get_width()
	var height = _weather_field_image.get_height()
	var avg_cloud = clampf(float(weather_snapshot.get("avg_cloud_cover", 0.0)), 0.0, 1.0)
	var avg_rain = clampf(float(weather_snapshot.get("avg_rain_intensity", 0.0)), 0.0, 1.0)
	var avg_humidity = clampf(float(weather_snapshot.get("avg_humidity", 0.0)), 0.0, 1.0)
	var avg_fog = clampf(float(weather_snapshot.get("avg_fog_intensity", 0.0)), 0.0, 1.0)
	var fill_color = Color(avg_cloud, avg_rain, avg_humidity, avg_fog)
	var avg_pack = _pack_weather_color(fill_color)
	var rows: Array = weather_snapshot.get("rows", [])
	var expected_cells = width * height
	var dirty_count = 0
	if rows.size() < expected_cells and avg_pack != _weather_field_last_avg_pack:
		_fill_weather_field(fill_color, avg_pack)
		dirty_count = expected_cells
	_weather_field_last_avg_pack = avg_pack
	for row_variant in rows:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var x = int(row.get("x", -1))
		var y = int(row.get("y", -1))
		if x < 0 or x >= width or y < 0 or y >= height:
			continue
		var pixel = Color(
			clampf(float(row.get("cloud", avg_cloud)), 0.0, 1.0),
			clampf(float(row.get("rain", avg_rain)), 0.0, 1.0),
			clampf(float(row.get("humidity", avg_humidity)), 0.0, 1.0),
			clampf(float(row.get("fog", avg_fog)), 0.0, 1.0)
		)
		var pack = _pack_weather_color(pixel)
		var idx = y * width + x
		if idx < 0 or idx >= _weather_field_cache.size():
			continue
		if _weather_field_cache[idx] == pack:
			continue
		_weather_field_cache[idx] = pack
		_weather_field_image.set_pixel(x, y, pixel)
		dirty_count += 1
	if dirty_count <= 0:
		return
	_weather_field_texture.update(_weather_field_image)

func _apply_weather_field_uniforms(shader_material: ShaderMaterial) -> void:
	if shader_material == null:
		return
	shader_material.set_shader_parameter("weather_field_tex", _weather_field_texture)
	shader_material.set_shader_parameter("weather_field_world_size", _weather_field_world_size)
	shader_material.set_shader_parameter("weather_field_blend", 1.0)

func _pack_weather_color(c: Color) -> int:
	var r = int(clampi(int(round(c.r * 255.0)), 0, 255))
	var g = int(clampi(int(round(c.g * 255.0)), 0, 255))
	var b = int(clampi(int(round(c.b * 255.0)), 0, 255))
	var a = int(clampi(int(round(c.a * 255.0)), 0, 255))
	return r | (g << 8) | (b << 16) | (a << 24)

func _fill_weather_field(color: Color, pack: int) -> void:
	if _weather_field_image == null:
		return
	_weather_field_image.fill(color)
	for i in range(_weather_field_cache.size()):
		_weather_field_cache[i] = pack

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
