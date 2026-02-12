extends Node3D

const WorldGeneratorScript = preload("res://addons/local_agents/simulation/WorldGenerator.gd")
const HydrologySystemScript = preload("res://addons/local_agents/simulation/HydrologySystem.gd")
const WeatherSystemScript = preload("res://addons/local_agents/simulation/WeatherSystem.gd")
const ErosionSystemScript = preload("res://addons/local_agents/simulation/ErosionSystem.gd")
const WorldGenConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")
const FlowArrowPulseShader = preload("res://addons/local_agents/scenes/simulation/shaders/FlowArrowPulse.gdshader")
const AtmosphereCycleControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/AtmosphereCycleController.gd")

@onready var _environment_controller: Node3D = $EnvironmentController
@onready var _flow_overlay_root: Node3D = $FlowOverlayRoot
@onready var _camera: Camera3D = $Camera3D
@onready var _sun_light: DirectionalLight3D = $DirectionalLight3D
@onready var _world_environment: WorldEnvironment = $WorldEnvironment
@onready var _seed_line_edit: LineEdit = %SeedLineEdit
@onready var _random_seed_button: Button = %RandomSeedButton
@onready var _generate_button: Button = %GenerateButton
@onready var _width_spin: SpinBox = %WidthSpinBox
@onready var _depth_spin: SpinBox = %DepthSpinBox
@onready var _world_height_spin: SpinBox = %WorldHeightSpinBox
@onready var _sea_level_spin: SpinBox = %SeaLevelSpinBox
@onready var _surface_range_spin: SpinBox = %SurfaceRangeSpinBox
@onready var _noise_frequency_spin: SpinBox = %NoiseFrequencySpinBox
@onready var _cave_threshold_spin: SpinBox = %CaveThresholdSpinBox
@onready var _show_flow_checkbox: CheckBox = %ShowFlowCheckBox
@onready var _flow_strength_threshold_spin: SpinBox = %FlowStrengthThresholdSpinBox
@onready var _flow_stride_spin: SpinBox = %FlowStrideSpinBox
@onready var _water_flow_speed_spin: SpinBox = %WaterFlowSpeedSpinBox
@onready var _water_noise_scale_spin: SpinBox = %WaterNoiseScaleSpinBox
@onready var _water_foam_strength_spin: SpinBox = %WaterFoamStrengthSpinBox
@onready var _water_wave_strength_spin: SpinBox = %WaterWaveStrengthSpinBox
@onready var _water_flow_dir_x_spin: SpinBox = %WaterFlowDirXSpinBox
@onready var _water_flow_dir_z_spin: SpinBox = %WaterFlowDirZSpinBox
@onready var _stats_label: Label = %StatsLabel
@onready var _simulation_hud: CanvasLayer = $SimulationHud

var _world_generator = WorldGeneratorScript.new()
var _hydrology = HydrologySystemScript.new()
var _weather = WeatherSystemScript.new()
var _erosion = ErosionSystemScript.new()
var _rng := RandomNumberGenerator.new()
var _atmosphere_cycle = AtmosphereCycleControllerScript.new()
@export var day_night_cycle_enabled: bool = true
@export var day_length_seconds: float = 140.0
@export_range(0.0, 1.0, 0.001) var start_time_of_day: float = 0.24
@export var weather_simulation_enabled: bool = true
@export_range(0.1, 8.0, 0.1) var weather_ticks_per_second: float = 2.0
var _time_of_day: float = 0.24
var _sim_accum: float = 0.0
var _sim_tick: int = 0
var _world_snapshot: Dictionary = {}
var _hydrology_snapshot: Dictionary = {}
var _weather_snapshot: Dictionary = {}
var _erosion_snapshot: Dictionary = {}
var _landslide_count: int = 0
var _is_playing: bool = true
var _ticks_per_frame: int = 1
var _fork_index: int = 0
var _active_branch_id: String = "main"
var _timelapse_snapshots: Dictionary = {}

func _ready() -> void:
	_rng.randomize()
	_time_of_day = clampf(start_time_of_day, 0.0, 1.0)
	_random_seed_button.pressed.connect(_on_random_seed_pressed)
	_generate_button.pressed.connect(_generate_world)
	_show_flow_checkbox.toggled.connect(func(_enabled: bool): _generate_world())
	_seed_line_edit.text_submitted.connect(func(_text: String): _generate_world())
	_water_flow_speed_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_noise_scale_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_foam_strength_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_wave_strength_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_flow_dir_x_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_flow_dir_z_spin.value_changed.connect(_on_water_shader_control_changed)
	if _simulation_hud != null:
		_simulation_hud.play_pressed.connect(_on_hud_play_pressed)
		_simulation_hud.pause_pressed.connect(_on_hud_pause_pressed)
		_simulation_hud.fast_forward_pressed.connect(_on_hud_fast_forward_pressed)
		_simulation_hud.rewind_pressed.connect(_on_hud_rewind_pressed)
		_simulation_hud.fork_pressed.connect(_on_hud_fork_pressed)
	_on_random_seed_pressed()

func _process(delta: float) -> void:
	_update_day_night(delta)
	if _is_playing:
		_step_environment_simulation(delta * float(_ticks_per_frame))
	_refresh_hud()

func _on_random_seed_pressed() -> void:
	_seed_line_edit.text = "demo_%d" % _rng.randi_range(10000, 99999)
	_generate_world()

func _generate_world() -> void:
	var config = WorldGenConfigResourceScript.new()
	config.map_width = int(_width_spin.value)
	config.map_height = int(_depth_spin.value)
	config.voxel_world_height = int(_world_height_spin.value)
	config.voxel_sea_level = int(_sea_level_spin.value)
	config.voxel_surface_height_range = int(_surface_range_spin.value)
	config.voxel_noise_frequency = float(_noise_frequency_spin.value)
	config.cave_noise_threshold = float(_cave_threshold_spin.value)
	config.voxel_surface_height_base = maxi(2, int(float(config.voxel_world_height) * 0.22))

	var seed_text = _seed_line_edit.text.strip_edges()
	if seed_text == "":
		seed_text = "demo_seed"
		_seed_line_edit.text = seed_text
	var seed = int(hash(seed_text))
	var world = _world_generator.generate(seed, config)
	var hydrology = _hydrology.build_network(world, config)
	_world_snapshot = world.duplicate(true)
	_hydrology_snapshot = hydrology.duplicate(true)
	_sim_tick = 0
	_sim_accum = 0.0
	_landslide_count = 0
	_active_branch_id = "main"
	_is_playing = true
	_ticks_per_frame = 1
	_timelapse_snapshots.clear()
	var weather_seed = int(hash("%s_weather" % seed_text))
	var erosion_seed = int(hash("%s_erosion" % seed_text))
	_weather.configure_environment(_world_snapshot, _hydrology_snapshot, weather_seed)
	_weather_snapshot = _weather.current_snapshot(0)
	_erosion.configure_environment(_world_snapshot, _hydrology_snapshot, erosion_seed)
	_erosion_snapshot = _erosion.current_snapshot(0)

	if _environment_controller.has_method("apply_generation_data"):
		_environment_controller.apply_generation_data(_world_snapshot, _hydrology_snapshot)
	if _environment_controller.has_method("set_weather_state"):
		_environment_controller.set_weather_state(_weather_snapshot)
	_apply_water_shader_controls()
	_render_flow_overlay(_world_snapshot, config)
	_frame_camera(_world_snapshot)
	_update_stats(_world_snapshot, _hydrology_snapshot, seed)
	_record_timelapse_snapshot(_sim_tick)

func _on_water_shader_control_changed(_value: float) -> void:
	_apply_water_shader_controls()

func _apply_water_shader_controls() -> void:
	if _environment_controller == null:
		return
	if not _environment_controller.has_method("set_water_shader_params"):
		return
	var flow_dir = Vector2(_water_flow_dir_x_spin.value, _water_flow_dir_z_spin.value)
	if flow_dir.length_squared() < 0.0001:
		flow_dir = Vector2(1.0, 0.0)
	_environment_controller.call("set_water_shader_params", {
		"flow_dir": flow_dir.normalized(),
		"flow_speed": _water_flow_speed_spin.value,
		"noise_scale": _water_noise_scale_spin.value,
		"foam_strength": _water_foam_strength_spin.value,
		"wave_strength": _water_wave_strength_spin.value,
	})

func _step_environment_simulation(delta: float) -> void:
	if not weather_simulation_enabled:
		return
	if _world_snapshot.is_empty() or _hydrology_snapshot.is_empty():
		return
	var tick_duration = 1.0 / maxf(0.1, weather_ticks_per_second)
	_sim_accum += maxf(0.0, delta)
	var terrain_changed = false
	var changed_tiles_map: Dictionary = {}
	while _sim_accum >= tick_duration:
		_sim_accum -= tick_duration
		_sim_tick += 1
		_weather_snapshot = _weather.step(_sim_tick, tick_duration)
		var erosion_result: Dictionary = _erosion.step(
			_sim_tick,
			tick_duration,
			_world_snapshot,
			_hydrology_snapshot,
			_weather_snapshot
		)
		_world_snapshot = erosion_result.get("environment", _world_snapshot)
		_hydrology_snapshot = erosion_result.get("hydrology", _hydrology_snapshot)
		_erosion_snapshot = erosion_result.get("erosion", _erosion_snapshot)
		terrain_changed = terrain_changed or bool(erosion_result.get("changed", false))
		var changed_tiles: Array = erosion_result.get("changed_tiles", [])
		for tile_variant in changed_tiles:
			changed_tiles_map[String(tile_variant)] = true
		_record_timelapse_snapshot(_sim_tick)
	if _environment_controller.has_method("set_weather_state"):
		_environment_controller.set_weather_state(_weather_snapshot)
	_apply_water_shader_controls()
	if terrain_changed and _environment_controller.has_method("apply_generation_delta"):
		_environment_controller.apply_generation_delta(_world_snapshot, _hydrology_snapshot, changed_tiles_map.keys())
		if _show_flow_checkbox.button_pressed:
			var config = _current_worldgen_config()
			_render_flow_overlay(_world_snapshot, config)
		if _environment_controller.has_method("set_weather_state"):
			_environment_controller.set_weather_state(_weather_snapshot)
		_apply_water_shader_controls()
	elif terrain_changed and _environment_controller.has_method("apply_generation_data"):
		_environment_controller.apply_generation_data(_world_snapshot, _hydrology_snapshot)
		if _show_flow_checkbox.button_pressed:
			var config = _current_worldgen_config()
			_render_flow_overlay(_world_snapshot, config)
		if _environment_controller.has_method("set_weather_state"):
			_environment_controller.set_weather_state(_weather_snapshot)
		_apply_water_shader_controls()
	var slides: Array = _erosion_snapshot.get("recent_landslides", [])
	_landslide_count = slides.size()
	_update_stats(_world_snapshot, _hydrology_snapshot, int(hash(_seed_line_edit.text.strip_edges())))

func _record_timelapse_snapshot(tick: int) -> void:
	_timelapse_snapshots[tick] = {
		"tick": tick,
		"time_of_day": _time_of_day,
		"world": _world_snapshot.duplicate(true),
		"hydrology": _hydrology_snapshot.duplicate(true),
		"weather": _weather_snapshot.duplicate(true),
		"erosion": _erosion_snapshot.duplicate(true),
	}
	var keys = _timelapse_snapshots.keys()
	if keys.size() <= 480:
		return
	keys.sort()
	var drop_count = keys.size() - 480
	for i in range(drop_count):
		_timelapse_snapshots.erase(keys[i])

func _render_flow_overlay(world: Dictionary, config) -> void:
	for child in _flow_overlay_root.get_children():
		child.queue_free()
	if not _show_flow_checkbox.button_pressed:
		return
	var flow_map: Dictionary = world.get("flow_map", {})
	if flow_map.is_empty():
		return
	var rows: Array = flow_map.get("rows", [])
	var voxel_world: Dictionary = world.get("voxel_world", {})
	var columns: Array = voxel_world.get("columns", [])
	var surface_by_tile: Dictionary = {}
	for column_variant in columns:
		if not (column_variant is Dictionary):
			continue
		var column = column_variant as Dictionary
		var tile_id = "%d:%d" % [int(column.get("x", 0)), int(column.get("z", 0))]
		surface_by_tile[tile_id] = int(column.get("surface_y", 0))

	var stride = maxi(1, int(_flow_stride_spin.value))
	var strength_threshold = clampf(float(_flow_strength_threshold_spin.value), 0.0, 1.0)
	for i in range(0, rows.size(), stride):
		var row_variant = rows[i]
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var strength = clampf(float(row.get("channel_strength", 0.0)), 0.0, 1.0)
		if strength < strength_threshold:
			continue
		var dir_x = float(row.get("dir_x", 0.0))
		var dir_y = float(row.get("dir_y", 0.0))
		var direction = Vector2(dir_x, dir_y)
		if direction.length_squared() < 0.01:
			continue
		direction = direction.normalized()
		var x = int(row.get("x", 0))
		var z = int(row.get("y", 0))
		var tile_id = "%d:%d" % [x, z]
		var surface_y = int(surface_by_tile.get(tile_id, config.voxel_sea_level))
		var marker = MeshInstance3D.new()
		var mesh = BoxMesh.new()
		var length = 0.35 + strength * 0.8
		mesh.size = Vector3(0.08, 0.06, length)
		marker.mesh = mesh
		var color = Color(0.2, 0.75 + 0.2 * strength, 1.0 - 0.35 * strength, 1.0)
		var material = ShaderMaterial.new()
		material.shader = FlowArrowPulseShader
		material.set_shader_parameter("base_color", color)
		material.set_shader_parameter("strength", strength)
		material.set_shader_parameter("pulse_speed", 2.0 + strength * 3.0)
		marker.material_override = material
		marker.position = Vector3(float(x) + 0.5, float(surface_y) + 1.15, float(z) + 0.5)
		_flow_overlay_root.add_child(marker)
		marker.look_at(marker.global_position + Vector3(direction.x, 0.0, direction.y), Vector3.UP)

func _frame_camera(world: Dictionary) -> void:
	var width = float(world.get("width", 1))
	var depth = float(world.get("height", 1))
	var voxel_world: Dictionary = world.get("voxel_world", {})
	var world_height = float(voxel_world.get("height", 24))
	var center = Vector3(width * 0.5, world_height * 0.35, depth * 0.5)
	var distance = maxf(width, depth) * 1.05
	_camera.position = center + Vector3(distance * 0.75, world_height * 0.6 + 10.0, distance)
	_camera.look_at(center, Vector3.UP)

func _update_stats(world: Dictionary, hydrology: Dictionary, seed: int) -> void:
	var voxel_world: Dictionary = world.get("voxel_world", {})
	var block_counts: Dictionary = voxel_world.get("block_type_counts", {})
	var water_tiles: Dictionary = hydrology.get("water_tiles", {})
	var flow_map: Dictionary = world.get("flow_map", {})
	var max_flow = float(flow_map.get("max_flow", 0.0))
	var avg_rain = float(_weather_snapshot.get("avg_rain_intensity", 0.0))
	var avg_fog = float(_weather_snapshot.get("avg_fog_intensity", 0.0))
	_stats_label.text = "seed=%d | blocks=%d | water_tiles=%d | max_flow=%0.2f | rain=%0.2f | fog=%0.2f | slides=%d | tod=%0.2f" % [
		seed,
		int((voxel_world.get("block_rows", []) as Array).size()),
		int(water_tiles.size()),
		max_flow,
		avg_rain,
		avg_fog,
		_landslide_count,
		_time_of_day
	]

func _update_day_night(delta: float) -> void:
	if _sun_light == null:
		return
	_time_of_day = _atmosphere_cycle.advance_time(_time_of_day, delta, day_night_cycle_enabled, day_length_seconds)
	_atmosphere_cycle.apply_to_light_and_environment(
		_time_of_day,
		_sun_light,
		_world_environment,
		0.06,
		1.38,
		0.04,
		1.15,
		0.02,
		1.0,
		0.05,
		1.0
	)
	_apply_demo_fog()

func _apply_demo_fog() -> void:
	if _world_environment == null or _world_environment.environment == null:
		return
	var env: Environment = _world_environment.environment
	var humidity = clampf(float(_weather_snapshot.get("avg_humidity", 0.0)), 0.0, 1.0)
	var rain = clampf(float(_weather_snapshot.get("avg_rain_intensity", 0.0)), 0.0, 1.0)
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = lerpf(0.012, 0.075, clampf(humidity * 0.72 + rain * 0.28, 0.0, 1.0))
	env.volumetric_fog_emission_energy = lerpf(0.32, 0.88, 1.0 - absf(_time_of_day - 0.5) * 2.0)

func _current_worldgen_config() -> Resource:
	var config = WorldGenConfigResourceScript.new()
	config.map_width = int(_width_spin.value)
	config.map_height = int(_depth_spin.value)
	config.voxel_world_height = int(_world_height_spin.value)
	config.voxel_sea_level = int(_sea_level_spin.value)
	config.voxel_surface_height_range = int(_surface_range_spin.value)
	config.voxel_noise_frequency = float(_noise_frequency_spin.value)
	config.cave_noise_threshold = float(_cave_threshold_spin.value)
	config.voxel_surface_height_base = maxi(2, int(float(config.voxel_world_height) * 0.22))
	return config

func _restore_to_tick(target_tick: int) -> void:
	if _timelapse_snapshots.is_empty():
		return
	var keys = _timelapse_snapshots.keys()
	keys.sort()
	var selected_tick = -1
	for key_variant in keys:
		var key = int(key_variant)
		if key <= target_tick:
			selected_tick = key
		else:
			break
	if selected_tick < 0:
		selected_tick = int(keys[0])
	var snapshot: Dictionary = _timelapse_snapshots.get(selected_tick, {})
	if snapshot.is_empty():
		return
	_sim_tick = int(snapshot.get("tick", selected_tick))
	_time_of_day = clampf(float(snapshot.get("time_of_day", _time_of_day)), 0.0, 1.0)
	_world_snapshot = snapshot.get("world", {}).duplicate(true)
	_hydrology_snapshot = snapshot.get("hydrology", {}).duplicate(true)
	_weather_snapshot = snapshot.get("weather", {}).duplicate(true)
	_erosion_snapshot = snapshot.get("erosion", {}).duplicate(true)
	_weather.configure_environment(_world_snapshot, _hydrology_snapshot, int(_weather_snapshot.get("seed", 0)))
	_weather.import_snapshot(_weather_snapshot)
	_erosion.configure_environment(_world_snapshot, _hydrology_snapshot, int(_erosion_snapshot.get("seed", 0)))
	_erosion.import_snapshot(_erosion_snapshot)
	var slides: Array = _erosion_snapshot.get("recent_landslides", [])
	_landslide_count = slides.size()
	if _environment_controller.has_method("apply_generation_data"):
		_environment_controller.apply_generation_data(_world_snapshot, _hydrology_snapshot)
	if _show_flow_checkbox.button_pressed:
		_render_flow_overlay(_world_snapshot, _current_worldgen_config())
	if _environment_controller.has_method("set_weather_state"):
		_environment_controller.set_weather_state(_weather_snapshot)
	_apply_water_shader_controls()
	_update_stats(_world_snapshot, _hydrology_snapshot, int(hash(_seed_line_edit.text.strip_edges())))

func _refresh_hud() -> void:
	if _simulation_hud == null:
		return
	var mode = "playing" if _is_playing else "paused"
	_simulation_hud.set_status_text("Tick %d | Branch %s | %s x%d" % [_sim_tick, _active_branch_id, mode, _ticks_per_frame])
	var avg_rain = clampf(float(_weather_snapshot.get("avg_rain_intensity", 0.0)), 0.0, 1.0)
	var avg_cloud = clampf(float(_weather_snapshot.get("avg_cloud_cover", 0.0)), 0.0, 1.0)
	var avg_fog = clampf(float(_weather_snapshot.get("avg_fog_intensity", 0.0)), 0.0, 1.0)
	var details = "Rain: %.2f | Cloud: %.2f | Fog: %.2f | Landslides: %d" % [avg_rain, avg_cloud, avg_fog, _landslide_count]
	if _simulation_hud.has_method("set_details_text"):
		_simulation_hud.set_details_text(details)

func _on_hud_play_pressed() -> void:
	_is_playing = true
	_ticks_per_frame = 1
	_refresh_hud()

func _on_hud_pause_pressed() -> void:
	_is_playing = false
	_refresh_hud()

func _on_hud_fast_forward_pressed() -> void:
	_is_playing = true
	_ticks_per_frame = 4 if _ticks_per_frame == 1 else 1
	_refresh_hud()

func _on_hud_rewind_pressed() -> void:
	_is_playing = false
	_restore_to_tick(maxi(0, _sim_tick - 24))
	_refresh_hud()

func _on_hud_fork_pressed() -> void:
	_fork_index += 1
	_active_branch_id = "branch_%02d" % _fork_index
	_refresh_hud()
