extends Node3D

const CloudRendererScript = preload("res://addons/local_agents/scenes/simulation/controllers/renderers/CloudRenderer.gd")
const RiverRendererScript = preload("res://addons/local_agents/scenes/simulation/controllers/renderers/RiverRenderer.gd")
const PostFXRendererScript = preload("res://addons/local_agents/scenes/simulation/controllers/renderers/PostFXRenderer.gd")
const WaterSourceRendererScript = preload("res://addons/local_agents/scenes/simulation/controllers/renderers/WaterSourceRenderer.gd")
const TerrainRendererScript = preload("res://addons/local_agents/scenes/simulation/controllers/renderers/TerrainRenderer.gd")
const AtmosphereSystemAdapterScript = preload("res://addons/local_agents/scenes/simulation/controllers/adapters/AtmosphereSystemAdapter.gd")
const OceanSystemAdapterScript = preload("res://addons/local_agents/scenes/simulation/controllers/adapters/OceanSystemAdapter.gd")
const PostFxSystemAdapterScript = preload("res://addons/local_agents/scenes/simulation/controllers/adapters/PostFxSystemAdapter.gd")
const LightingSystemAdapterScript = preload("res://addons/local_agents/scenes/simulation/controllers/adapters/LightingSystemAdapter.gd")

@onready var terrain_root: Node3D = $TerrainRoot
@onready var water_root: Node3D = $WaterRoot
@export_range(4, 64, 1) var terrain_chunk_size: int = 12
@export_enum("simple", "shader") var water_render_mode: String = "simple"
@export var ocean_surface_enabled: bool = false
@export var river_overlays_enabled: bool = false
@export var rain_post_fx_enabled: bool = false
@export var clouds_enabled: bool = false
@export_range(0.2, 2.0, 0.05) var cloud_density_scale: float = 0.25
@export_range(0.1, 1.5, 0.05) var rain_visual_intensity_scale: float = 0.25
@export_enum("low", "medium", "high", "ultra") var cloud_quality_tier: String = "medium"
@export_range(0.25, 3.0, 0.05) var cloud_slice_density: float = 0.8
@export_range(1, 16, 1) var weather_texture_update_interval_ticks: int = 4
@export_range(1, 16, 1) var surface_texture_update_interval_ticks: int = 4
@export_range(1, 16, 1) var solar_texture_update_interval_ticks: int = 4
@export_range(512, 65536, 512) var field_texture_update_budget_cells: int = 8192
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
var _surface_field_update_cursor: int = 0
var _solar_field_image: Image
var _solar_field_texture: ImageTexture
var _solar_field_cache := PackedInt32Array()
var _solar_field_last_tick: int = -1
var _solar_field_update_cursor: int = 0
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
	"moon_dir": Vector2(1.0, 0.0),
	"moon_phase": 0.5,
	"moon_tidal_strength": 1.0,
	"moon_tide_range": 0.26,
	"lunar_wave_boost": 0.4,
	"gravity_source_pos": Vector2(0.0, 0.0),
	"gravity_source_strength": 1.0,
	"gravity_source_radius": 96.0,
	"ocean_wave_amplitude": 0.18,
	"ocean_wave_frequency": 0.65,
	"ocean_chop": 0.55,
	"ocean_detail": 0.66,
	"camera_world_pos": Vector3.ZERO,
	"far_simplify_start": 24.0,
	"far_simplify_end": 96.0,
	"far_detail_min": 0.28,
	"weather_field_blend": 1.0,
}
var _cloud_renderer
var _river_renderer
var _post_fx_renderer
var _water_source_renderer
var _terrain_renderer
var _lightning_flash: float = 0.0
var _ocean_root: Node3D
var _ocean_mesh_instance: MeshInstance3D
var _ocean_material: ShaderMaterial
var _ocean_plane_mesh: PlaneMesh
var _ocean_size_cache: Vector2 = Vector2.ZERO
var _ocean_sea_level_cache: float = -INF
var _last_lightning_uniform: float = -1.0
var _weather_field_update_cursor: int = 0
var _atmosphere_adapter
var _ocean_adapter
var _post_fx_adapter
var _lighting_adapter

func _process(_delta: float) -> void:
	_poll_chunk_build()
	_ensure_system_adapters()
	_lighting_adapter.process(self, _delta)

func _exit_tree() -> void:
	_wait_for_chunk_build()

func clear_generated() -> void:
	_ensure_renderer_nodes()
	_terrain_renderer.clear_generated()
	for child in water_root.get_children():
		child.queue_free()
	if _ocean_root != null and is_instance_valid(_ocean_root):
		for child in _ocean_root.get_children():
			child.queue_free()
	_ensure_renderer_nodes()
	_cloud_renderer.clear_generated()
	_river_renderer.clear_generated()
	_post_fx_renderer.clear_generated()
	if _ocean_root != null and is_instance_valid(_ocean_root):
		_ocean_root.visible = ocean_surface_enabled

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
	_ensure_ocean_surface()
	_update_cloud_layer_geometry()
	_update_ocean_surface_geometry()
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
	_update_ocean_surface_geometry()
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
	var rain = clampf(float(_weather_snapshot.get("avg_rain_intensity", 0.0)) * rain_visual_intensity_scale, 0.0, 1.0)
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
	_ensure_system_adapters()
	if _cloud_renderer == null:
		_cloud_renderer = CloudRendererScript.new()
		_cloud_renderer.name = "CloudRenderer"
		add_child(_cloud_renderer)
	_apply_cloud_quality_settings()
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
	if _ocean_root == null or not is_instance_valid(_ocean_root):
		_ocean_root = Node3D.new()
		_ocean_root.name = "OceanRoot"
		add_child(_ocean_root)

func _ensure_system_adapters() -> void:
	if _atmosphere_adapter == null:
		_atmosphere_adapter = AtmosphereSystemAdapterScript.new()
	if _ocean_adapter == null:
		_ocean_adapter = OceanSystemAdapterScript.new()
	if _post_fx_adapter == null:
		_post_fx_adapter = PostFxSystemAdapterScript.new()
	if _lighting_adapter == null:
		_lighting_adapter = LightingSystemAdapterScript.new()

func _sync_terrain_renderer_context() -> void:
	_ensure_renderer_nodes()
	_terrain_renderer.set_weather_snapshot(_weather_snapshot)
	_terrain_renderer.set_water_render_mode(water_render_mode)
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
	_apply_ocean_material_uniforms()

func set_water_shader_params(params: Dictionary) -> void:
	for key_variant in params.keys():
		var key = String(key_variant)
		_water_shader_params[key] = params.get(key_variant)
	_sync_terrain_renderer_context()
	_terrain_renderer.set_water_shader_params(params)
	_apply_ocean_material_uniforms()

func set_terrain_chunk_size(next_size: int) -> void:
	var clamped = clampi(next_size, 4, 64)
	if clamped == terrain_chunk_size:
		return
	terrain_chunk_size = clamped
	if _generation_snapshot.is_empty():
		return
	_request_chunk_rebuild([])

func set_water_render_mode(next_mode: String) -> void:
	var normalized = String(next_mode).to_lower().strip_edges()
	if normalized != "shader":
		normalized = "simple"
	if water_render_mode == normalized:
		return
	water_render_mode = normalized
	_sync_terrain_renderer_context()
	_request_chunk_rebuild([])

func set_ocean_surface_enabled(enabled: bool) -> void:
	ocean_surface_enabled = enabled
	if ocean_surface_enabled:
		_ensure_ocean_surface()
		_update_ocean_surface_geometry()
	else:
		if _ocean_root != null and is_instance_valid(_ocean_root):
			_ocean_root.visible = false

func set_river_overlays_enabled(enabled: bool) -> void:
	river_overlays_enabled = enabled
	_rebuild_river_flow_overlays()

func set_rain_post_fx_enabled(enabled: bool) -> void:
	rain_post_fx_enabled = enabled
	_ensure_rain_post_fx()

func set_clouds_enabled(enabled: bool) -> void:
	clouds_enabled = enabled
	_ensure_cloud_layer()
	_ensure_volumetric_cloud_shell()
	_update_cloud_layer_geometry()

func set_cloud_density_scale(scale: float) -> void:
	cloud_density_scale = clampf(scale, 0.2, 2.0)
	set_cloud_quality_settings(cloud_quality_tier, cloud_density_scale)

func set_rain_visual_intensity_scale(scale: float) -> void:
	rain_visual_intensity_scale = clampf(scale, 0.1, 1.5)
	if not _weather_snapshot.is_empty():
		set_weather_state(_weather_snapshot)

func get_graphics_state() -> Dictionary:
	return {
		"water_shader_enabled": water_render_mode == "shader",
		"ocean_surface_enabled": ocean_surface_enabled,
		"river_overlays_enabled": river_overlays_enabled,
		"rain_post_fx_enabled": rain_post_fx_enabled,
		"clouds_enabled": clouds_enabled,
		"cloud_quality": cloud_quality_tier,
		"cloud_density_scale": cloud_density_scale,
		"rain_visual_intensity_scale": rain_visual_intensity_scale,
	}

func _apply_weather_to_cached_materials(rain: float, cloud: float, humidity: float) -> void:
	_sync_terrain_renderer_context()
	_terrain_renderer.apply_weather_to_materials(rain, cloud, humidity)

func _request_chunk_rebuild(chunk_keys: Array = []) -> void:
	var voxel_world: Dictionary = _generation_snapshot.get("voxel_world", {})
	var block_rows: Array = voxel_world.get("block_rows", [])
	if block_rows.is_empty() or terrain_root == null:
		return
	var chunk_rows_by_chunk: Dictionary = voxel_world.get("block_rows_by_chunk", {})
	var chunk_rows_chunk_size = int(voxel_world.get("block_rows_chunk_size", 0))
	var normalized_chunk_keys: Array = []
	for key_variant in chunk_keys:
		var key = String(key_variant).strip_edges()
		if key == "":
			continue
		normalized_chunk_keys.append(key)
	normalized_chunk_keys.sort()
	_sync_terrain_renderer_context()
	_terrain_renderer.request_chunk_rebuild(
		block_rows,
		normalized_chunk_keys,
		terrain_chunk_size,
		chunk_rows_by_chunk,
		chunk_rows_chunk_size
	)

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
	if not river_overlays_enabled:
		_river_renderer.clear_generated()
		return
	_river_renderer.rebuild_overlays(_generation_snapshot, _weather_snapshot)

func _update_river_material_weather(rain: float, cloud: float, wind: Vector2, wind_speed: float) -> void:
	if not river_overlays_enabled:
		return
	_ensure_renderer_nodes()
	_river_renderer.update_weather(rain, cloud, wind_speed)
	_river_renderer.apply_lightning(_lightning_flash)

func _ensure_volumetric_cloud_shell() -> void:
	_ensure_system_adapters()
	_atmosphere_adapter.ensure_volumetric_cloud_shell(self)

func _update_volumetric_cloud_geometry() -> void:
	_ensure_system_adapters()
	_atmosphere_adapter.update_volumetric_cloud_geometry(self)

func _update_volumetric_cloud_weather(rain: float, cloud: float, humidity: float, wind: Vector2, wind_speed: float) -> void:
	_ensure_system_adapters()
	_atmosphere_adapter.update_volumetric_cloud_weather(self, rain, cloud, humidity, wind, wind_speed)

func _ensure_rain_post_fx() -> void:
	_ensure_system_adapters()
	_post_fx_adapter.ensure_rain_post_fx(self)

func _update_rain_post_fx_weather(rain: float, wind: Vector2, wind_speed: float) -> void:
	_ensure_system_adapters()
	_post_fx_adapter.update_rain_post_fx_weather(self, rain, wind, wind_speed)

func _ensure_cloud_layer() -> void:
	_ensure_system_adapters()
	_atmosphere_adapter.ensure_cloud_layer(self)

func _update_cloud_layer_geometry() -> void:
	_ensure_system_adapters()
	_atmosphere_adapter.update_cloud_layer_geometry(self)

func _update_cloud_layer_weather(rain: float, cloud: float, humidity: float, wind: Vector2, wind_speed: float) -> void:
	_ensure_system_adapters()
	_atmosphere_adapter.update_cloud_layer_weather(self, rain, cloud, humidity, wind, wind_speed)

func set_cloud_quality_settings(tier: String, slice_density: float) -> void:
	_ensure_system_adapters()
	_atmosphere_adapter.set_cloud_quality_settings(self, tier, slice_density)

func _apply_cloud_quality_settings() -> void:
	_ensure_system_adapters()
	_atmosphere_adapter.apply_cloud_quality_settings(self)

func _ensure_weather_field_texture() -> void:
	_ensure_system_adapters()
	_atmosphere_adapter.ensure_weather_field_texture(self)

func _ensure_surface_field_texture() -> void:
	_ensure_system_adapters()
	_atmosphere_adapter.ensure_surface_field_texture(self)

func _ensure_solar_field_texture() -> void:
	_ensure_system_adapters()
	_atmosphere_adapter.ensure_solar_field_texture(self)

func _refresh_surface_state_from_generation() -> void:
	_ensure_system_adapters()
	_atmosphere_adapter.refresh_surface_state_from_generation(self)

func _update_surface_state_texture(weather_snapshot: Dictionary) -> void:
	_ensure_system_adapters()
	_atmosphere_adapter.update_surface_state_texture(self, weather_snapshot)

func _update_solar_field_texture(solar_snapshot: Dictionary) -> void:
	_ensure_system_adapters()
	_atmosphere_adapter.update_solar_field_texture(self, solar_snapshot)

func _update_weather_field_texture(weather_snapshot: Dictionary) -> void:
	_ensure_system_adapters()
	_atmosphere_adapter.update_weather_field_texture(self, weather_snapshot)

func trigger_lightning(intensity: float = 1.0) -> void:
	_ensure_system_adapters()
	_lighting_adapter.trigger_lightning(self, intensity)

func _update_lightning_uniforms() -> void:
	_ensure_system_adapters()
	_lighting_adapter.update_lightning_uniforms(self)

func _ensure_ocean_surface() -> void:
	_ensure_system_adapters()
	_ocean_adapter.ensure_ocean_surface(self)

func _update_ocean_surface_geometry() -> void:
	_ensure_system_adapters()
	_ocean_adapter.update_ocean_surface_geometry(self)

func _apply_ocean_material_uniforms() -> void:
	_ensure_system_adapters()
	_ocean_adapter.apply_ocean_material_uniforms(self)

func _pack_weather_color(c: Color) -> int:
	_ensure_system_adapters()
	return _atmosphere_adapter.pack_weather_color(c)

func _fill_weather_field(color: Color, pack: int) -> void:
	_ensure_system_adapters()
	_atmosphere_adapter.fill_weather_field(self, color, pack)
