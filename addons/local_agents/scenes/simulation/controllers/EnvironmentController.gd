extends Node3D

const CloudRendererScript = preload("res://addons/local_agents/scenes/simulation/controllers/renderers/CloudRenderer.gd")
const RiverRendererScript = preload("res://addons/local_agents/scenes/simulation/controllers/renderers/RiverRenderer.gd")
const PostFXRendererScript = preload("res://addons/local_agents/scenes/simulation/controllers/renderers/PostFXRenderer.gd")
const WaterSourceRendererScript = preload("res://addons/local_agents/scenes/simulation/controllers/renderers/WaterSourceRenderer.gd")
const TerrainRendererScript = preload("res://addons/local_agents/scenes/simulation/controllers/renderers/TerrainRenderer.gd")

@onready var terrain_root: Node3D = $TerrainRoot
@onready var water_root: Node3D = $WaterRoot
@export_range(4, 64, 1) var terrain_chunk_size: int = 12
var _generation_snapshot: Dictionary = {}
var _hydrology_snapshot: Dictionary = {}
var _weather_snapshot: Dictionary = {}
var _solar_snapshot: Dictionary = {}
var _weather_field_image: Image
var _weather_field_texture: ImageTexture
var _weather_field_world_size: Vector2 = Vector2.ONE
var _weather_field_cache := PackedInt32Array()
var _weather_field_last_avg_pack: int = -1
var _surface_field_image: Image
var _surface_field_texture: ImageTexture
var _surface_field_cache := PackedInt32Array()
var _surface_field_last_update_tick: int = -1
var _solar_field_image: Image
var _solar_field_texture: ImageTexture
var _solar_field_cache := PackedInt32Array()
var _solar_field_last_tick: int = -1
var _tile_temperature_map := PackedFloat32Array()
var _tile_flow_map := PackedFloat32Array()
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
var _cloud_renderer
var _river_renderer
var _post_fx_renderer
var _water_source_renderer
var _terrain_renderer
var _lightning_flash: float = 0.0

func _process(_delta: float) -> void:
	_poll_chunk_build()
	_lightning_flash = maxf(0.0, _lightning_flash - _delta * 2.6)
	_update_lightning_uniforms()

func _exit_tree() -> void:
	_wait_for_chunk_build()

func clear_generated() -> void:
	_ensure_renderer_nodes()
	_terrain_renderer.clear_generated()
	for child in water_root.get_children():
		child.queue_free()
	_ensure_renderer_nodes()
	_cloud_renderer.clear_generated()
	_river_renderer.clear_generated()
	_post_fx_renderer.clear_generated()

func apply_generation_data(generation: Dictionary, hydrology: Dictionary) -> void:
	_generation_snapshot = generation.duplicate(true)
	_hydrology_snapshot = hydrology.duplicate(true)
	_ensure_weather_field_texture()
	_ensure_surface_field_texture()
	_ensure_solar_field_texture()
	_request_chunk_rebuild([])
	_rebuild_water_sources()
	_rebuild_river_flow_overlays()
	_ensure_cloud_layer()
	_ensure_volumetric_cloud_shell()
	_ensure_rain_post_fx()
	_update_cloud_layer_geometry()
	_update_weather_field_texture(_weather_snapshot)
	_refresh_surface_state_from_generation()
	_update_surface_state_texture(_weather_snapshot)
	_update_solar_field_texture(_solar_snapshot)

func apply_generation_delta(generation: Dictionary, hydrology: Dictionary, changed_tiles: Array) -> void:
	_generation_snapshot = generation.duplicate(true)
	_hydrology_snapshot = hydrology.duplicate(true)
	_ensure_weather_field_texture()
	_ensure_surface_field_texture()
	_ensure_solar_field_texture()
	_update_weather_field_texture(_weather_snapshot)
	_update_surface_state_texture(_weather_snapshot)
	_update_solar_field_texture(_solar_snapshot)
	var chunk_keys = _chunk_keys_for_changed_tiles(changed_tiles)
	if chunk_keys.is_empty():
		_request_chunk_rebuild([])
		_rebuild_water_sources()
		return
	_request_chunk_rebuild(chunk_keys)

func _rebuild_water_sources() -> void:
	_ensure_renderer_nodes()
	_water_source_renderer.rebuild_sources(water_root, _hydrology_snapshot)

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
	_update_river_material_weather(rain, cloud, wind, wind_speed)
	_update_volumetric_cloud_weather(rain, cloud, humidity, wind, wind_speed)
	_update_rain_post_fx_weather(rain, wind, wind_speed)

func _ensure_renderer_nodes() -> void:
	if _cloud_renderer == null:
		_cloud_renderer = CloudRendererScript.new()
		_cloud_renderer.name = "CloudRenderer"
		add_child(_cloud_renderer)
	if _river_renderer == null:
		_river_renderer = RiverRendererScript.new()
		_river_renderer.name = "RiverRenderer"
		add_child(_river_renderer)
	if _post_fx_renderer == null:
		_post_fx_renderer = PostFXRendererScript.new()
		_post_fx_renderer.name = "PostFXRenderer"
		add_child(_post_fx_renderer)
	if _water_source_renderer == null:
		_water_source_renderer = WaterSourceRendererScript.new()
		_water_source_renderer.name = "WaterSourceRenderer"
		add_child(_water_source_renderer)
	if _terrain_renderer == null:
		_terrain_renderer = TerrainRendererScript.new()
		_terrain_renderer.configure(terrain_root)

func _sync_terrain_renderer_context() -> void:
	_ensure_renderer_nodes()
	_terrain_renderer.set_weather_snapshot(_weather_snapshot)
	_terrain_renderer.set_render_context(
		_water_shader_params,
		_weather_field_texture,
		_weather_field_world_size,
		_surface_field_texture,
		_solar_field_texture
	)

func set_solar_state(solar_snapshot: Dictionary) -> void:
	_solar_snapshot = solar_snapshot.duplicate(true)
	_update_solar_field_texture(_solar_snapshot)
	_sync_terrain_renderer_context()
	_terrain_renderer.refresh_material_uniforms()

func set_water_shader_params(params: Dictionary) -> void:
	for key_variant in params.keys():
		var key = String(key_variant)
		_water_shader_params[key] = params.get(key_variant)
	_sync_terrain_renderer_context()
	_terrain_renderer.set_water_shader_params(params)

func _apply_weather_to_cached_materials(rain: float, cloud: float, humidity: float) -> void:
	_sync_terrain_renderer_context()
	_terrain_renderer.apply_weather_to_materials(rain, cloud, humidity)

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
	_sync_terrain_renderer_context()
	_terrain_renderer.request_chunk_rebuild(block_rows, normalized_chunk_keys, terrain_chunk_size)

func _poll_chunk_build() -> void:
	_ensure_renderer_nodes()
	_terrain_renderer.poll()

func _wait_for_chunk_build() -> void:
	_ensure_renderer_nodes()
	_terrain_renderer.wait_for_build()

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

func _rebuild_river_flow_overlays() -> void:
	_ensure_renderer_nodes()
	_river_renderer.rebuild_overlays(_generation_snapshot, _weather_snapshot)

func _update_river_material_weather(rain: float, cloud: float, wind: Vector2, wind_speed: float) -> void:
	_ensure_renderer_nodes()
	_river_renderer.update_weather(rain, cloud, wind_speed)
	_river_renderer.apply_lightning(_lightning_flash)

func _ensure_volumetric_cloud_shell() -> void:
	_ensure_renderer_nodes()
	_cloud_renderer.ensure_layers()
	_update_volumetric_cloud_geometry()

func _update_volumetric_cloud_geometry() -> void:
	_ensure_renderer_nodes()
	_cloud_renderer.update_geometry(_generation_snapshot)

func _update_volumetric_cloud_weather(rain: float, cloud: float, humidity: float, wind: Vector2, wind_speed: float) -> void:
	_update_cloud_layer_weather(rain, cloud, humidity, wind, wind_speed)

func _ensure_rain_post_fx() -> void:
	_ensure_renderer_nodes()
	_post_fx_renderer.ensure_layer()

func _update_rain_post_fx_weather(rain: float, wind: Vector2, wind_speed: float) -> void:
	_ensure_renderer_nodes()
	_post_fx_renderer.update_weather(rain, wind, wind_speed)
	_post_fx_renderer.apply_lightning(_lightning_flash)

func _ensure_cloud_layer() -> void:
	_ensure_renderer_nodes()
	_cloud_renderer.ensure_layers()

func _update_cloud_layer_geometry() -> void:
	_ensure_renderer_nodes()
	_cloud_renderer.update_geometry(_generation_snapshot)

func _update_cloud_layer_weather(rain: float, cloud: float, humidity: float, wind: Vector2, wind_speed: float) -> void:
	_ensure_renderer_nodes()
	_cloud_renderer.update_weather(
		rain,
		cloud,
		humidity,
		wind,
		wind_speed,
		_weather_field_texture,
		_weather_field_world_size,
		_lightning_flash
	)

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

func _ensure_surface_field_texture() -> void:
	var width = maxi(1, int(_generation_snapshot.get("width", 1)))
	var height = maxi(1, int(_generation_snapshot.get("height", 1)))
	var needs_recreate = (
		_surface_field_image == null
		or _surface_field_texture == null
		or _surface_field_image.get_width() != width
		or _surface_field_image.get_height() != height
	)
	if not needs_recreate:
		return
	_surface_field_image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	_surface_field_image.fill(Color(0.0, 0.0, 0.0, 1.0))
	_surface_field_texture = ImageTexture.create_from_image(_surface_field_image)
	_surface_field_cache.resize(width * height)
	for i in range(_surface_field_cache.size()):
		_surface_field_cache[i] = -1
	_tile_temperature_map.resize(width * height)
	_tile_flow_map.resize(width * height)
	for i in range(width * height):
		_tile_temperature_map[i] = 0.5
		_tile_flow_map[i] = 0.0
	_surface_field_last_update_tick = -1

func _ensure_solar_field_texture() -> void:
	var width = maxi(1, int(_generation_snapshot.get("width", 1)))
	var height = maxi(1, int(_generation_snapshot.get("height", 1)))
	var needs_recreate = (
		_solar_field_image == null
		or _solar_field_texture == null
		or _solar_field_image.get_width() != width
		or _solar_field_image.get_height() != height
	)
	if not needs_recreate:
		return
	_solar_field_image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	_solar_field_image.fill(Color(0.0, 0.0, 0.0, 1.0))
	_solar_field_texture = ImageTexture.create_from_image(_solar_field_image)
	_solar_field_cache.resize(width * height)
	for i in range(_solar_field_cache.size()):
		_solar_field_cache[i] = -1
	_solar_field_last_tick = -1

func _refresh_surface_state_from_generation() -> void:
	_ensure_surface_field_texture()
	if _surface_field_image == null:
		return
	var width = _surface_field_image.get_width()
	var height = _surface_field_image.get_height()
	var tile_index: Dictionary = _generation_snapshot.get("tile_index", {})
	var flow_rows_by_tile: Dictionary = {}
	var flow_rows: Array = (_generation_snapshot.get("flow_map", {}) as Dictionary).get("rows", [])
	for row_variant in flow_rows:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var tile_id = "%d:%d" % [int(row.get("x", 0)), int(row.get("y", 0))]
		flow_rows_by_tile[tile_id] = clampf(float(row.get("channel_strength", 0.0)), 0.0, 1.0)
	for y in range(height):
		for x in range(width):
			var idx = y * width + x
			var tile_id = "%d:%d" % [x, y]
			var tile = tile_index.get(tile_id, {})
			var temp = clampf(float((tile as Dictionary).get("temperature", 0.5)) if tile is Dictionary else 0.5, 0.0, 1.0)
			var flow = clampf(float(flow_rows_by_tile.get(tile_id, 0.0)), 0.0, 1.0)
			_tile_temperature_map[idx] = temp
			_tile_flow_map[idx] = flow
			var snow = clampf((0.34 - temp) * 2.2, 0.0, 1.0)
			var c = Color(0.0, snow, flow, 0.0)
			var pack = _pack_weather_color(c)
			_surface_field_cache[idx] = pack
			_surface_field_image.set_pixel(x, y, c)
	_surface_field_texture.update(_surface_field_image)

func _update_surface_state_texture(weather_snapshot: Dictionary) -> void:
	_ensure_surface_field_texture()
	if _surface_field_image == null or _surface_field_texture == null:
		return
	var tick = int(weather_snapshot.get("tick", -1))
	if tick == _surface_field_last_update_tick:
		return
	_surface_field_last_update_tick = tick
	var width = _surface_field_image.get_width()
	var height = _surface_field_image.get_height()
	var rows: Array = weather_snapshot.get("rows", [])
	var by_tile: Dictionary = {}
	for row_variant in rows:
		if row_variant is Dictionary:
			var row = row_variant as Dictionary
			by_tile["%d:%d" % [int(row.get("x", 0)), int(row.get("y", 0))]] = row
	var avg_rain = clampf(float(weather_snapshot.get("avg_rain_intensity", 0.0)), 0.0, 1.0)
	var avg_humidity = clampf(float(weather_snapshot.get("avg_humidity", 0.0)), 0.0, 1.0)
	var dirty = 0
	for y in range(height):
		for x in range(width):
			var idx = y * width + x
			var prev = _surface_field_image.get_pixel(x, y)
			var row = by_tile.get("%d:%d" % [x, y], {})
			var rain = clampf(float((row as Dictionary).get("rain", avg_rain)) if row is Dictionary else avg_rain, 0.0, 1.0)
			var humidity = clampf(float((row as Dictionary).get("humidity", avg_humidity)) if row is Dictionary else avg_humidity, 0.0, 1.0)
			var temp = _tile_temperature_map[idx] if idx < _tile_temperature_map.size() else 0.5
			var flow = _tile_flow_map[idx] if idx < _tile_flow_map.size() else 0.0
			var wet = clampf(prev.r * 0.965 + rain * 0.09 + humidity * 0.012, 0.0, 1.0)
			var snow = prev.g
			if temp < 0.34:
				snow = clampf(snow * 0.995 + rain * (0.024 + (0.34 - temp) * 0.02), 0.0, 1.0)
			else:
				snow = clampf(snow - (0.008 + temp * 0.018 + wet * 0.01), 0.0, 1.0)
			var erosion = clampf(prev.a * 0.986 + rain * flow * 0.022 + wet * flow * 0.009, 0.0, 1.0)
			var next = Color(wet, snow, flow, erosion)
			var pack = _pack_weather_color(next)
			if _surface_field_cache[idx] == pack:
				continue
			_surface_field_cache[idx] = pack
			_surface_field_image.set_pixel(x, y, next)
			dirty += 1
	if dirty > 0:
		_surface_field_texture.update(_surface_field_image)

func _update_solar_field_texture(solar_snapshot: Dictionary) -> void:
	_ensure_solar_field_texture()
	if _solar_field_image == null or _solar_field_texture == null:
		return
	var tick = int(solar_snapshot.get("tick", -1))
	if tick == _solar_field_last_tick:
		return
	_solar_field_last_tick = tick
	var width = _solar_field_image.get_width()
	var height = _solar_field_image.get_height()
	var avg_absorbed = clampf(float(solar_snapshot.get("avg_insolation", 0.0)), 0.0, 1.0)
	var avg_uv = clampf(float(solar_snapshot.get("avg_uv_index", 0.0)) / 2.0, 0.0, 1.0)
	var avg_heat = clampf(float(solar_snapshot.get("avg_heat_load", 0.0)) / 1.5, 0.0, 1.0)
	var avg_growth = clampf(float(solar_snapshot.get("avg_growth_factor", 0.0)), 0.0, 1.0)
	var rows: Array = solar_snapshot.get("rows", [])
	var dirty = 0
	var expected = width * height
	if rows.size() < expected:
		var fill = Color(avg_absorbed, avg_uv, avg_heat, avg_growth)
		var fill_pack = _pack_weather_color(fill)
		for i in range(_solar_field_cache.size()):
			if _solar_field_cache[i] == fill_pack:
				continue
			_solar_field_cache[i] = fill_pack
			var x = i % width
			var y = i / width
			_solar_field_image.set_pixel(x, y, fill)
			dirty += 1
	for row_variant in rows:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var tile_id = String(row.get("tile_id", ""))
		var parts = tile_id.split(":")
		if parts.size() != 2:
			continue
		var x = int(parts[0])
		var y = int(parts[1])
		if x < 0 or x >= width or y < 0 or y >= height:
			continue
		var c = Color(
			clampf(float(row.get("sunlight_absorbed", row.get("sunlight_total", 0.0))), 0.0, 1.5) / 1.5,
			clampf(float(row.get("uv_index", 0.0)), 0.0, 2.0) / 2.0,
			clampf(float(row.get("heat_load", 0.0)), 0.0, 1.5) / 1.5,
			clampf(float(row.get("plant_growth_factor", 0.0)), 0.0, 1.0)
		)
		var pack = _pack_weather_color(c)
		var idx = y * width + x
		if idx < 0 or idx >= _solar_field_cache.size():
			continue
		if _solar_field_cache[idx] == pack:
			continue
		_solar_field_cache[idx] = pack
		_solar_field_image.set_pixel(x, y, c)
		dirty += 1
	if dirty > 0:
		_solar_field_texture.update(_solar_field_image)

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

func trigger_lightning(intensity: float = 1.0) -> void:
	_lightning_flash = clampf(maxf(_lightning_flash, intensity), 0.0, 2.0)
	_update_lightning_uniforms()

func _update_lightning_uniforms() -> void:
	_ensure_renderer_nodes()
	_river_renderer.apply_lightning(_lightning_flash)
	_cloud_renderer.apply_lightning(_lightning_flash)
	_post_fx_renderer.apply_lightning(_lightning_flash)

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
