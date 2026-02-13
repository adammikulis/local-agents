extends Node3D
class_name LocalAgentsWorldSimulationController

const FlowTraversalProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowTraversalProfileResource.gd")
const WorldGenConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")
const WorldProgressionProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldProgressionProfileResource.gd")
const EnvironmentSignalSnapshotResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/EnvironmentSignalSnapshotResource.gd")
const AtmosphereCycleControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/AtmosphereCycleController.gd")
const SimulationLoopControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/SimulationLoopController.gd")

@onready var simulation_controller: Node = $SimulationController
@onready var environment_controller: Node3D = $EnvironmentController
@onready var settlement_controller: Node3D = $SettlementController
@onready var villager_controller: Node3D = $VillagerController
@onready var culture_controller: Node3D = $CultureController
@onready var debug_overlay_root: Node3D = $DebugOverlayRoot
@onready var simulation_hud: CanvasLayer = $SimulationHud
@onready var field_hud: CanvasLayer = get_node_or_null("FieldHud")
@onready var sun_light: DirectionalLight3D = $DirectionalLight3D
@onready var world_environment: WorldEnvironment = $WorldEnvironment
@onready var world_camera: Camera3D = $Camera3D
@export var world_seed_text: String = "world_progression_main"
@export var auto_generate_on_ready: bool = true
@export var auto_play_on_ready: bool = true
@export var auto_frame_camera_on_generate: bool = true
@export var camera_controls_enabled: bool = true
@export var orbit_sensitivity: float = 0.007
@export var pan_sensitivity: float = 0.01
@export var zoom_step_ratio: float = 0.1
@export var min_zoom_distance: float = 3.0
@export var max_zoom_distance: float = 120.0
@export var min_pitch_degrees: float = 18.0
@export var max_pitch_degrees: float = 82.0
@export var flow_traversal_profile_override: Resource
@export var worldgen_config_override: Resource
@export var world_progression_profile_override: Resource
@export var enable_cognition_runtime: bool = false
@export var start_year: float = -8000.0
@export var years_per_tick: float = 0.25
@export var start_simulated_seconds: float = 0.0
@export var simulated_seconds_per_tick: float = 1.0
@export_range(0.5, 30.0, 0.5) var simulation_ticks_per_second: float = 4.0
@export var day_night_cycle_enabled: bool = true
@export var day_length_seconds: float = 180.0
@export_range(0.0, 1.0, 0.001) var start_time_of_day: float = 0.28
@export_range(1, 16, 1) var visual_environment_update_interval_ticks: int = 4
@export_range(1, 16, 1) var living_profile_push_interval_ticks: int = 4

var _loop_controller = SimulationLoopControllerScript.new()
var _last_state: Dictionary = {}
var _inspector_npc_id: String = ""
var _time_of_day: float = 0.28
var _atmosphere_cycle = AtmosphereCycleControllerScript.new()
var _camera_focus: Vector3 = Vector3.ZERO
var _camera_distance: float = 16.0
var _camera_yaw: float = 0.0
var _camera_pitch: float = deg_to_rad(55.0)
var _mmb_down: bool = false
var _rmb_down: bool = false
var _spawn_mode: String = "none"
var _graphics_state: Dictionary = {
	"water_shader_enabled": false,
	"ocean_surface_enabled": false,
	"river_overlays_enabled": false,
	"rain_post_fx_enabled": false,
	"clouds_enabled": false,
	"cloud_quality": "low",
	"cloud_density_scale": 0.25,
	"rain_visual_intensity_scale": 0.25,
	"shadows_enabled": false,
	"ssr_enabled": false,
	"ssao_enabled": false,
	"ssil_enabled": false,
	"sdfgi_enabled": false,
	"glow_enabled": false,
	"fog_enabled": false,
	"volumetric_fog_enabled": false,
}

func _ready() -> void:
	_time_of_day = clampf(start_time_of_day, 0.0, 1.0)
	_loop_controller.configure(
		simulation_controller,
		start_year,
		years_per_tick,
		start_simulated_seconds,
		simulated_seconds_per_tick
	)
	_loop_controller.set_timing(simulation_ticks_per_second, living_profile_push_interval_ticks)
	if flow_traversal_profile_override == null:
		flow_traversal_profile_override = FlowTraversalProfileResourceScript.new()
	if worldgen_config_override == null:
		worldgen_config_override = WorldGenConfigResourceScript.new()
	if world_progression_profile_override == null:
		world_progression_profile_override = WorldProgressionProfileResourceScript.new()
	if simulation_controller.has_method("set_flow_traversal_profile") and flow_traversal_profile_override != null:
		simulation_controller.set_flow_traversal_profile(flow_traversal_profile_override)
	if simulation_hud != null:
		simulation_hud.play_pressed.connect(_on_hud_play_pressed)
		simulation_hud.pause_pressed.connect(_on_hud_pause_pressed)
		simulation_hud.fast_forward_pressed.connect(_on_hud_fast_forward_pressed)
		simulation_hud.rewind_pressed.connect(_on_hud_rewind_pressed)
		simulation_hud.fork_pressed.connect(_on_hud_fork_pressed)
		if simulation_hud.has_signal("inspector_npc_changed"):
			simulation_hud.inspector_npc_changed.connect(_on_hud_inspector_npc_changed)
		if simulation_hud.has_signal("overlays_changed"):
			simulation_hud.overlays_changed.connect(_on_hud_overlays_changed)
		if simulation_hud.has_signal("graphics_option_changed"):
			simulation_hud.graphics_option_changed.connect(_on_hud_graphics_option_changed)
		if simulation_hud.has_signal("performance_mode_requested"):
			simulation_hud.performance_mode_requested.connect(_on_hud_performance_mode_requested)
	_initialize_camera_orbit()
	_on_hud_overlays_changed(false, false, false, false, false, false)
	_apply_graphics_state()
	if has_node("EcologyController"):
		var ecology_controller = get_node("EcologyController")
		if ecology_controller.has_method("set_debug_overlay"):
			ecology_controller.call("set_debug_overlay", debug_overlay_root)
	if field_hud != null:
		if field_hud.has_signal("spawn_mode_requested"):
			field_hud.connect("spawn_mode_requested", _on_field_spawn_mode_requested)
		if field_hud.has_signal("spawn_random_requested"):
			field_hud.connect("spawn_random_requested", _on_field_spawn_random_requested)
		if field_hud.has_signal("debug_settings_changed"):
			field_hud.connect("debug_settings_changed", _on_field_debug_settings_changed)
		if field_hud.has_method("set_spawn_mode"):
			field_hud.call("set_spawn_mode", _spawn_mode)
		if field_hud.has_method("set_status"):
			field_hud.call("set_status", "Select mode active")
	if not auto_generate_on_ready:
		return
	if simulation_controller.has_method("configure"):
		simulation_controller.configure(world_seed_text, false, false)
	if simulation_controller.has_method("set_cognition_features"):
		simulation_controller.set_cognition_features(enable_cognition_runtime, enable_cognition_runtime, enable_cognition_runtime)
	if not simulation_controller.has_method("configure_environment"):
		return
	_apply_year_progression(worldgen_config_override, _year_at_tick(0))
	var setup: Dictionary = simulation_controller.configure_environment(worldgen_config_override)
	if not bool(setup.get("ok", false)):
		return
	if environment_controller.has_method("apply_generation_data"):
		environment_controller.apply_generation_data(
			setup.get("environment", {}),
			setup.get("hydrology", {})
		)
	if environment_controller.has_method("set_weather_state"):
		environment_controller.set_weather_state(setup.get("weather", {}))
	if environment_controller.has_method("set_solar_state"):
		environment_controller.set_solar_state(setup.get("solar", {}))
	if auto_frame_camera_on_generate:
		_frame_camera_from_environment(setup.get("environment", {}))
	_apply_environment_signals(_build_environment_signal_snapshot_from_setup(setup, 0))
	if settlement_controller.has_method("spawn_initial_settlement"):
		settlement_controller.spawn_initial_settlement(setup.get("spawn", {}))
	var initial_snapshot: Dictionary = {}
	if simulation_controller.has_method("current_snapshot"):
		initial_snapshot = simulation_controller.current_snapshot(0)
	_loop_controller.initialize_from_snapshot(0, auto_play_on_ready, initial_snapshot)
	_last_state = _loop_controller.last_state()
	if not _last_state.is_empty():
		_sync_environment_from_state(_last_state, false)
	_refresh_hud()

func _process(_delta: float) -> void:
	_update_day_night(_delta)
	_apply_loop_result(_loop_controller.process_frame(_delta, Callable(self, "_collect_living_entity_profiles")))

func _unhandled_input(event: InputEvent) -> void:
	if not camera_controls_enabled:
		return
	if event is InputEventMouseMotion:
		_handle_camera_mouse_motion(event as InputEventMouseMotion)
		return
	if event is InputEventMouseButton:
		var mouse_event = event as InputEventMouseButton
		_handle_camera_mouse_button(mouse_event)
		if mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed and _spawn_mode != "none":
			_handle_spawn_click(mouse_event.position)

func _on_field_spawn_mode_requested(mode: String) -> void:
	_spawn_mode = mode
	if field_hud != null and field_hud.has_method("set_spawn_mode"):
		field_hud.call("set_spawn_mode", _spawn_mode)
	if field_hud != null and field_hud.has_method("set_status"):
		if _spawn_mode == "none":
			field_hud.call("set_status", "Select mode active")
		else:
			field_hud.call("set_status", "Click ground to spawn %s" % _spawn_mode)

func _on_field_spawn_random_requested(plants: int, rabbits: int) -> void:
	if has_node("EcologyController"):
		var ecology_controller = get_node("EcologyController")
		if ecology_controller.has_method("spawn_random"):
			ecology_controller.call("spawn_random", plants, rabbits)
	if field_hud != null and field_hud.has_method("set_status"):
		field_hud.call("set_status", "Spawned random: %d plants, %d rabbits" % [plants, rabbits])

func _on_field_debug_settings_changed(settings: Dictionary) -> void:
	if has_node("EcologyController"):
		var ecology_controller = get_node("EcologyController")
		if ecology_controller.has_method("apply_debug_settings"):
			ecology_controller.call("apply_debug_settings", settings)

func _handle_spawn_click(screen_pos: Vector2) -> void:
	if _spawn_mode == "none":
		return
	if not has_node("EcologyController"):
		return
	var ecology_controller = get_node("EcologyController")
	var point = _screen_to_ground(screen_pos)
	if point == null:
		return
	if _spawn_mode == "plant" and ecology_controller.has_method("spawn_plant_at"):
		ecology_controller.call("spawn_plant_at", point, 0.0)
	elif _spawn_mode == "rabbit" and ecology_controller.has_method("spawn_rabbit_at"):
		ecology_controller.call("spawn_rabbit_at", point)
	_spawn_mode = "none"
	if field_hud != null and field_hud.has_method("set_spawn_mode"):
		field_hud.call("set_spawn_mode", _spawn_mode)
	if field_hud != null and field_hud.has_method("set_status"):
		field_hud.call("set_status", "Selection mode restored")

func _screen_to_ground(screen_pos: Vector2) -> Variant:
	if world_camera == null:
		return null
	var origin := world_camera.project_ray_origin(screen_pos)
	var direction := world_camera.project_ray_normal(screen_pos)
	var hit = Plane(Vector3.UP, 0.0).intersects_ray(origin, direction)
	if hit == null:
		return null
	return Vector3(hit)

func _collect_living_entity_profiles():
	if has_node("EcologyController"):
		var ecology_controller = get_node("EcologyController")
		if ecology_controller.has_method("collect_living_entity_profiles"):
			return ecology_controller.call("collect_living_entity_profiles")
	return null

func _apply_loop_result(result: Dictionary) -> void:
	var state_changed := bool(result.get("state_changed", false))
	if not state_changed:
		return
	var force_rebuild := bool(result.get("force_rebuild", false))
	var state_advanced := bool(result.get("state_advanced", false))
	if state_advanced or force_rebuild:
		_last_state = _loop_controller.last_state()
		if not _last_state.is_empty():
			_sync_environment_from_state(_last_state, force_rebuild)
	_refresh_hud()

func _sync_environment_from_state(state: Dictionary, force_rebuild: bool) -> void:
	if environment_controller == null:
		return
	if state.is_empty():
		return
	var env_signals = _build_environment_signal_snapshot_from_state(state)
	var tick = _loop_controller.current_tick()
	var do_visual_update := force_rebuild or (tick % maxi(1, visual_environment_update_interval_ticks) == 0)
	if force_rebuild or bool(env_signals.erosion_changed):
		if not force_rebuild and environment_controller.has_method("apply_generation_delta"):
			environment_controller.apply_generation_delta(
				env_signals.environment_snapshot,
				env_signals.water_network_snapshot,
				env_signals.erosion_changed_tiles
			)
		elif environment_controller.has_method("apply_generation_data"):
			environment_controller.apply_generation_data(
				env_signals.environment_snapshot,
				env_signals.water_network_snapshot
			)
	if do_visual_update and environment_controller.has_method("set_weather_state"):
		environment_controller.set_weather_state(env_signals.weather_snapshot)
	if do_visual_update and environment_controller.has_method("set_solar_state"):
		environment_controller.set_solar_state(env_signals.solar_snapshot)
	_apply_environment_signals(env_signals)

func _on_hud_play_pressed() -> void:
	_apply_loop_result(_loop_controller.play())

func _on_hud_pause_pressed() -> void:
	_apply_loop_result(_loop_controller.pause())

func _on_hud_fast_forward_pressed() -> void:
	_apply_loop_result(_loop_controller.toggle_fast_forward())

func _on_hud_rewind_pressed() -> void:
	_apply_loop_result(_loop_controller.rewind_ticks(24))

func _on_hud_fork_pressed() -> void:
	_apply_loop_result(_loop_controller.fork_branch_from_current_tick())

func _refresh_hud() -> void:
	if simulation_hud == null:
		return
	var branch_id = "main"
	if simulation_controller.has_method("get_active_branch_id"):
		branch_id = String(simulation_controller.get_active_branch_id())
	var current_tick = _loop_controller.current_tick()
	var mode = "playing" if _loop_controller.is_playing() else "paused"
	var year = _loop_controller.simulated_year()
	var time_text = _format_duration_hms(_loop_controller.simulated_seconds())
	simulation_hud.set_status_text("Year %.1f | T+%s | Tick %d | Branch %s | %s x%d" % [year, time_text, current_tick, branch_id, mode, _loop_controller.ticks_per_frame()])

	var detail_lines: Array[String] = []
	_ensure_inspector_npc_selected()
	var inspector_lines = _inspector_summary_lines(current_tick)
	for line in inspector_lines:
		detail_lines.append(String(line))
	if branch_id != "main" and simulation_controller.has_method("branch_diff"):
		var diff: Dictionary = simulation_controller.branch_diff("main", branch_id, maxi(0, current_tick - 48), current_tick)
		if bool(diff.get("ok", false)):
			var pop_delta = int(diff.get("population_delta", 0))
			var belief_delta = int(diff.get("belief_divergence", 0))
			var culture_delta = float(diff.get("culture_continuity_score_delta", 0.0))
			detail_lines.append("Diff vs main: pop %+d | belief %+d | culture %+0.3f" % [pop_delta, belief_delta, culture_delta])
	var details_text = "\n".join(detail_lines)
	if simulation_hud.has_method("set_details_text"):
		simulation_hud.set_details_text(details_text)
	if simulation_hud.has_method("set_inspector_npc"):
		simulation_hud.set_inspector_npc(_inspector_npc_id)

func _build_environment_signal_snapshot_from_setup(setup: Dictionary, tick: int) -> LocalAgentsEnvironmentSignalSnapshotResource:
	var snapshot = EnvironmentSignalSnapshotResourceScript.new()
	snapshot.tick = tick
	snapshot.environment_snapshot = setup.get("environment", {}).duplicate(true)
	snapshot.water_network_snapshot = setup.get("hydrology", {}).duplicate(true)
	snapshot.weather_snapshot = setup.get("weather", {}).duplicate(true)
	snapshot.erosion_snapshot = setup.get("erosion", {}).duplicate(true)
	snapshot.solar_snapshot = setup.get("solar", {}).duplicate(true)
	return snapshot

func _build_environment_signal_snapshot_from_state(state: Dictionary) -> LocalAgentsEnvironmentSignalSnapshotResource:
	var snapshot = EnvironmentSignalSnapshotResourceScript.new()
	var signals_variant = state.get("environment_signals", {})
	if signals_variant is Dictionary:
		snapshot.from_dict(signals_variant as Dictionary)
	else:
		snapshot.tick = int(state.get("tick", _loop_controller.current_tick()))
		snapshot.environment_snapshot = state.get("environment_snapshot", {}).duplicate(true)
		snapshot.water_network_snapshot = state.get("water_network_snapshot", {}).duplicate(true)
		snapshot.weather_snapshot = state.get("weather_snapshot", {}).duplicate(true)
		snapshot.erosion_snapshot = state.get("erosion_snapshot", {}).duplicate(true)
		snapshot.solar_snapshot = state.get("solar_snapshot", {}).duplicate(true)
		snapshot.erosion_changed = bool(state.get("erosion_changed", false))
		snapshot.erosion_changed_tiles = (state.get("erosion_changed_tiles", []) as Array).duplicate(true)
	return snapshot

func _apply_environment_signals(snapshot: LocalAgentsEnvironmentSignalSnapshotResource) -> void:
	if not has_node("EcologyController"):
		return
	var ecology_controller = get_node("EcologyController")
	if ecology_controller.has_method("set_environment_signals"):
		ecology_controller.call("set_environment_signals", snapshot)

func _update_day_night(delta: float) -> void:
	if sun_light == null:
		return
	_time_of_day = _atmosphere_cycle.advance_time(_time_of_day, delta, day_night_cycle_enabled, day_length_seconds)
	var atmosphere_state: Dictionary = _atmosphere_cycle.apply_to_light_and_environment(
		_time_of_day,
		sun_light,
		world_environment,
		0.08,
		1.32,
		0.06,
		1.08,
		0.03,
		0.95,
		0.06,
		1.0
	)
	_apply_atmospheric_fog(float(atmosphere_state.get("daylight", 0.0)))

func _apply_atmospheric_fog(daylight: float) -> void:
	if world_environment == null or world_environment.environment == null:
		return
	var env: Environment = world_environment.environment
	var fog_enabled = bool(_graphics_state.get("fog_enabled", false))
	var volumetric_fog_enabled = bool(_graphics_state.get("volumetric_fog_enabled", false))
	_set_env_flag_if_supported(env, "fog_enabled", fog_enabled)
	_set_env_flag_if_supported(env, "volumetric_fog_enabled", volumetric_fog_enabled)

func _year_at_tick(tick: int) -> float:
	return start_year + float(tick) * years_per_tick

func _apply_year_progression(config: Resource, year: float) -> void:
	if config == null:
		return
	if world_progression_profile_override != null and world_progression_profile_override.has_method("apply_to_worldgen_config"):
		world_progression_profile_override.call("apply_to_worldgen_config", config, year)
		return
	config.set("simulated_year", year)
	config.set("progression_profile_id", "year_%d" % int(round(year)))

func _format_duration_hms(total_seconds: float) -> String:
	var whole = maxi(0, int(floor(total_seconds)))
	var hours = int(whole / 3600)
	var minutes = int((whole % 3600) / 60)
	var seconds = int(whole % 60)
	return "%02d:%02d:%02d" % [hours, minutes, seconds]

func _on_hud_inspector_npc_changed(npc_id: String) -> void:
	var normalized = npc_id.strip_edges()
	_inspector_npc_id = normalized
	_refresh_hud()

func _on_hud_overlays_changed(paths: bool, resources: bool, conflicts: bool, smell: bool, wind: bool, temperature: bool) -> void:
	if debug_overlay_root == null:
		return
	if debug_overlay_root.has_method("set_visibility_flags"):
		debug_overlay_root.call("set_visibility_flags", paths, resources, conflicts, smell, wind, temperature)

func _on_hud_graphics_option_changed(option_id: String, value) -> void:
	_graphics_state[String(option_id)] = value
	_apply_graphics_state()

func _apply_graphics_state() -> void:
	if sun_light != null:
		sun_light.shadow_enabled = bool(_graphics_state.get("shadows_enabled", false))
	if world_environment != null and world_environment.environment != null:
		var env: Environment = world_environment.environment
		_set_env_flag_if_supported(env, "ssr_enabled", bool(_graphics_state.get("ssr_enabled", false)))
		_set_env_flag_if_supported(env, "ssao_enabled", bool(_graphics_state.get("ssao_enabled", false)))
		_set_env_flag_if_supported(env, "ssil_enabled", bool(_graphics_state.get("ssil_enabled", false)))
		_set_env_flag_if_supported(env, "sdfgi_enabled", bool(_graphics_state.get("sdfgi_enabled", false)))
		_set_env_flag_if_supported(env, "glow_enabled", bool(_graphics_state.get("glow_enabled", false)))
		_set_env_flag_if_supported(env, "fog_enabled", bool(_graphics_state.get("fog_enabled", false)))
		_set_env_flag_if_supported(env, "volumetric_fog_enabled", bool(_graphics_state.get("volumetric_fog_enabled", false)))
	if environment_controller != null:
		if environment_controller.has_method("set_water_render_mode"):
			environment_controller.call("set_water_render_mode", "shader" if bool(_graphics_state.get("water_shader_enabled", false)) else "simple")
		if environment_controller.has_method("set_ocean_surface_enabled"):
			environment_controller.call("set_ocean_surface_enabled", bool(_graphics_state.get("ocean_surface_enabled", false)))
		if environment_controller.has_method("set_river_overlays_enabled"):
			environment_controller.call("set_river_overlays_enabled", bool(_graphics_state.get("river_overlays_enabled", false)))
		if environment_controller.has_method("set_rain_post_fx_enabled"):
			environment_controller.call("set_rain_post_fx_enabled", bool(_graphics_state.get("rain_post_fx_enabled", false)))
		if environment_controller.has_method("set_clouds_enabled"):
			environment_controller.call("set_clouds_enabled", bool(_graphics_state.get("clouds_enabled", false)))
		if environment_controller.has_method("set_cloud_quality_settings"):
			environment_controller.call("set_cloud_quality_settings", String(_graphics_state.get("cloud_quality", "low")), float(_graphics_state.get("cloud_density_scale", 0.25)))
		if environment_controller.has_method("set_cloud_density_scale"):
			environment_controller.call("set_cloud_density_scale", float(_graphics_state.get("cloud_density_scale", 0.25)))
		if environment_controller.has_method("set_rain_visual_intensity_scale"):
			environment_controller.call("set_rain_visual_intensity_scale", float(_graphics_state.get("rain_visual_intensity_scale", 0.25)))
		if environment_controller.has_method("get_graphics_state"):
			var env_state = environment_controller.call("get_graphics_state")
			if env_state is Dictionary:
				for key_variant in (env_state as Dictionary).keys():
					_graphics_state[String(key_variant)] = (env_state as Dictionary).get(key_variant)
	if simulation_hud != null and simulation_hud.has_method("set_graphics_state"):
		simulation_hud.call("set_graphics_state", _graphics_state)

func _set_env_flag_if_supported(env: Environment, property_name: String, enabled: bool) -> void:
	if env == null:
		return
	for prop in env.get_property_list():
		if String((prop as Dictionary).get("name", "")) == property_name:
			env.set(property_name, enabled)
			return

func _ensure_inspector_npc_selected() -> void:
	if _inspector_npc_id != "":
		return
	var villagers: Dictionary = _last_state.get("villagers", {})
	var ids = villagers.keys()
	ids.sort_custom(func(a, b): return String(a) < String(b))
	if ids.is_empty():
		return
	_inspector_npc_id = String(ids[0])

func _inspector_summary_lines(tick: int) -> Array[String]:
	var lines: Array[String] = []
	if _inspector_npc_id == "":
		lines.append("Inspector: no npc selected")
		return lines
	lines.append("Inspector NPC: %s" % _inspector_npc_id)
	lines.append("Inspector details trimmed for performance")
	return lines

func _frame_camera_from_environment(environment_snapshot: Dictionary) -> void:
	if world_camera == null:
		return
	if environment_snapshot.is_empty():
		return
	var width = float(environment_snapshot.get("width", 1))
	var depth = float(environment_snapshot.get("height", 1))
	var voxel_world: Dictionary = environment_snapshot.get("voxel_world", {})
	var world_height = float(voxel_world.get("height", 24))
	var center = Vector3(width * 0.5, world_height * 0.35, depth * 0.5)
	var distance = maxf(width, depth) * 1.05
	world_camera.position = center + Vector3(distance * 0.75, world_height * 0.6 + 10.0, distance)
	world_camera.look_at(center, Vector3.UP)
	_camera_focus = center
	_rebuild_orbit_state_from_camera()

func _initialize_camera_orbit() -> void:
	if world_camera == null:
		return
	_camera_focus = Vector3.ZERO
	_rebuild_orbit_state_from_camera()

func _rebuild_orbit_state_from_camera() -> void:
	if world_camera == null:
		return
	var offset := world_camera.global_position - _camera_focus
	_camera_distance = clampf(offset.length(), min_zoom_distance, max_zoom_distance)
	if _camera_distance > 0.001:
		_camera_pitch = clampf(asin(offset.y / _camera_distance), deg_to_rad(min_pitch_degrees), deg_to_rad(max_pitch_degrees))
		_camera_yaw = atan2(offset.x, offset.z)

func _handle_camera_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		_mmb_down = event.pressed
		return
	if event.button_index == MOUSE_BUTTON_RIGHT:
		_rmb_down = event.pressed
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
		_camera_distance = maxf(min_zoom_distance, _camera_distance * (1.0 - zoom_step_ratio))
		_apply_camera_transform()
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
		_camera_distance = minf(max_zoom_distance, _camera_distance * (1.0 + zoom_step_ratio))
		_apply_camera_transform()
		return

func _handle_camera_mouse_motion(event: InputEventMouseMotion) -> void:
	if not _mmb_down and not _rmb_down:
		return
	if _rmb_down or Input.is_key_pressed(KEY_SHIFT):
		_pan_camera(event.relative)
	else:
		_orbit_camera(event.relative)
	_apply_camera_transform()

func _orbit_camera(relative: Vector2) -> void:
	_camera_yaw -= relative.x * orbit_sensitivity
	_camera_pitch = clampf(
		_camera_pitch - relative.y * orbit_sensitivity,
		deg_to_rad(min_pitch_degrees),
		deg_to_rad(max_pitch_degrees)
	)

func _pan_camera(relative: Vector2) -> void:
	if world_camera == null:
		return
	var right := world_camera.global_transform.basis.x
	right.y = 0.0
	if right.length_squared() > 0.0001:
		right = right.normalized()
	var forward := -world_camera.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() > 0.0001:
		forward = forward.normalized()
	var scale := pan_sensitivity * _camera_distance
	_camera_focus += (-right * relative.x + forward * relative.y) * scale
	_camera_focus.y = maxf(0.0, _camera_focus.y)

func _apply_camera_transform() -> void:
	if world_camera == null:
		return
	var horizontal := cos(_camera_pitch) * _camera_distance
	var offset := Vector3(
		sin(_camera_yaw) * horizontal,
		sin(_camera_pitch) * _camera_distance,
		cos(_camera_yaw) * horizontal
	)
	world_camera.global_position = _camera_focus + offset
	world_camera.look_at(_camera_focus, Vector3.UP)
