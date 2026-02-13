extends Node3D
class_name LocalAgentsWorldSimulationController

const FlowTraversalProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowTraversalProfileResource.gd")
const WorldGenConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")
const WorldProgressionProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldProgressionProfileResource.gd")
const AtmosphereCycleControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/AtmosphereCycleController.gd")
const SimulationLoopControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/SimulationLoopController.gd")
const SimulationGraphicsSettingsScript = preload("res://addons/local_agents/scenes/simulation/controllers/SimulationGraphicsSettings.gd")
const WorldCameraControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldCameraController.gd")
const WorldHudBindingControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldHudBindingController.gd")
const WorldEnvironmentSyncControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldEnvironmentSyncController.gd")

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
@export_range(1, 8, 1) var hud_refresh_interval_ticks: int = 2

var _loop_controller = SimulationLoopControllerScript.new()
var _last_state: Dictionary = {}
var _time_of_day: float = 0.28
var _atmosphere_cycle = AtmosphereCycleControllerScript.new()
var _spawn_mode: String = "none"
var _graphics_state: Dictionary = SimulationGraphicsSettingsScript.default_state()
var _last_hud_refresh_tick: int = -1

var _camera_controller = WorldCameraControllerScript.new()
var _hud_binding_controller = WorldHudBindingControllerScript.new()
var _environment_sync_controller = WorldEnvironmentSyncControllerScript.new()
var _ecology_controller: Node = null

func _ready() -> void:
	_graphics_state = SimulationGraphicsSettingsScript.merge_with_defaults(_graphics_state)
	_time_of_day = clampf(start_time_of_day, 0.0, 1.0)
	_loop_controller.configure(simulation_controller, start_year, years_per_tick, start_simulated_seconds, simulated_seconds_per_tick)
	_loop_controller.set_timing(simulation_ticks_per_second, living_profile_push_interval_ticks)
	if has_node("EcologyController"):
		_ecology_controller = get_node("EcologyController")

	if flow_traversal_profile_override == null:
		flow_traversal_profile_override = FlowTraversalProfileResourceScript.new()
	if worldgen_config_override == null:
		worldgen_config_override = WorldGenConfigResourceScript.new()
	if world_progression_profile_override == null:
		world_progression_profile_override = WorldProgressionProfileResourceScript.new()
	if simulation_controller.has_method("set_flow_traversal_profile") and flow_traversal_profile_override != null:
		simulation_controller.set_flow_traversal_profile(flow_traversal_profile_override)

	_camera_controller.configure(world_camera, orbit_sensitivity, pan_sensitivity, zoom_step_ratio, min_zoom_distance, max_zoom_distance, min_pitch_degrees, max_pitch_degrees)
	_environment_sync_controller.configure(environment_controller, world_environment, sun_light, simulation_controller, _ecology_controller, _loop_controller, _atmosphere_cycle)
	_environment_sync_controller.cache_environment_supported_flags()

	_hud_binding_controller.connect_simulation_hud(simulation_hud, {
		"play": Callable(self, "_on_hud_play_pressed"),
		"pause": Callable(self, "_on_hud_pause_pressed"),
		"fast_forward": Callable(self, "_on_hud_fast_forward_pressed"),
		"rewind": Callable(self, "_on_hud_rewind_pressed"),
		"fork": Callable(self, "_on_hud_fork_pressed"),
		"inspector_npc_changed": Callable(self, "_on_hud_inspector_npc_changed"),
		"overlays_changed": Callable(self, "_on_hud_overlays_changed"),
		"graphics_option_changed": Callable(self, "_on_hud_graphics_option_changed")
	})
	_hud_binding_controller.connect_field_hud(field_hud, {
		"spawn_mode_requested": Callable(self, "_on_field_spawn_mode_requested"),
		"spawn_random_requested": Callable(self, "_on_field_spawn_random_requested"),
		"debug_settings_changed": Callable(self, "_on_field_debug_settings_changed")
	}, _spawn_mode)

	_initialize_camera_orbit()
	_on_hud_overlays_changed(false, false, false, false, false, false)
	_apply_graphics_state()
	if _ecology_controller != null and _ecology_controller.has_method("set_debug_overlay"):
		_ecology_controller.call("set_debug_overlay", debug_overlay_root)
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
		environment_controller.apply_generation_data(setup.get("environment", {}), setup.get("hydrology", {}))
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

func _process(delta: float) -> void:
	_update_day_night(delta)
	_push_native_view_metrics()
	_apply_loop_result(_loop_controller.process_frame(delta, Callable(self, "_collect_living_entity_profiles")))

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
	_hud_binding_controller.set_field_spawn_mode(field_hud, _spawn_mode)

func _on_field_spawn_random_requested(plants: int, rabbits: int) -> void:
	if _ecology_controller != null and _ecology_controller.has_method("spawn_random"):
		_ecology_controller.call("spawn_random", plants, rabbits)
	_hud_binding_controller.set_field_random_spawn_status(field_hud, plants, rabbits)

func _on_field_debug_settings_changed(settings: Dictionary) -> void:
	if _ecology_controller != null and _ecology_controller.has_method("apply_debug_settings"):
		_ecology_controller.call("apply_debug_settings", settings)

func _handle_spawn_click(screen_pos: Vector2) -> void:
	if _spawn_mode == "none" or _ecology_controller == null:
		return
	var point = _screen_to_ground(screen_pos)
	if point == null:
		return
	if _spawn_mode == "plant" and _ecology_controller.has_method("spawn_plant_at"):
		_ecology_controller.call("spawn_plant_at", point, 0.0)
	elif _spawn_mode == "rabbit" and _ecology_controller.has_method("spawn_rabbit_at"):
		_ecology_controller.call("spawn_rabbit_at", point)
	_spawn_mode = "none"
	if field_hud != null and field_hud.has_method("set_spawn_mode"):
		field_hud.call("set_spawn_mode", _spawn_mode)
	_hud_binding_controller.set_field_selection_restored(field_hud)

func _collect_living_entity_profiles():
	if _ecology_controller != null and _ecology_controller.has_method("collect_living_entity_profiles"):
		return _ecology_controller.call("collect_living_entity_profiles")
	return null

func _apply_loop_result(result: Dictionary) -> void:
	if not bool(result.get("state_changed", false)):
		return
	var force_rebuild := bool(result.get("force_rebuild", false))
	if bool(result.get("state_advanced", false)) or force_rebuild:
		_last_state = _loop_controller.last_state()
		if not _last_state.is_empty():
			_sync_environment_from_state(_last_state, force_rebuild)
	var current_tick = _loop_controller.current_tick()
	if force_rebuild or _last_hud_refresh_tick < 0 or current_tick % maxi(1, hud_refresh_interval_ticks) == 0:
		_last_hud_refresh_tick = current_tick
		_refresh_hud()

func _sync_environment_from_state(state: Dictionary, force_rebuild: bool) -> void:
	_environment_sync_controller.sync_from_state(state, force_rebuild, visual_environment_update_interval_ticks)

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
	_hud_binding_controller.refresh_hud(simulation_hud, simulation_controller, _loop_controller, _last_state)

func _build_environment_signal_snapshot_from_setup(setup: Dictionary, tick: int):
	return _environment_sync_controller.build_snapshot_from_setup(setup, tick)

func _build_environment_signal_snapshot_from_state(state: Dictionary):
	return _environment_sync_controller.build_snapshot_from_state(state, _loop_controller.current_tick())

func _apply_environment_signals(snapshot) -> void:
	_environment_sync_controller.apply_environment_signals(snapshot)

func _update_day_night(delta: float) -> void:
	_time_of_day = _environment_sync_controller.update_day_night(
		delta,
		_time_of_day,
		day_night_cycle_enabled,
		day_length_seconds,
		_graphics_state
	)

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

func _on_hud_inspector_npc_changed(npc_id: String) -> void:
	_hud_binding_controller.on_inspector_npc_changed(npc_id)
	_refresh_hud()

func _on_hud_overlays_changed(paths: bool, resources: bool, conflicts: bool, smell: bool, wind: bool, temperature: bool) -> void:
	if debug_overlay_root != null and debug_overlay_root.has_method("set_visibility_flags"):
		debug_overlay_root.call("set_visibility_flags", paths, resources, conflicts, smell, wind, temperature)

func _on_hud_graphics_option_changed(option_id: String, value) -> void:
	var key := String(option_id)
	_graphics_state[key] = _environment_sync_controller.sanitize_graphics_value(key, value)
	_apply_graphics_state()

func _apply_graphics_state() -> void:
	_graphics_state = _environment_sync_controller.apply_graphics_state(
		_graphics_state,
		simulation_ticks_per_second,
		living_profile_push_interval_ticks
	)
	if _graphics_state.has("_visual_environment_update_interval_ticks"):
		visual_environment_update_interval_ticks = maxi(1, int(_graphics_state.get("_visual_environment_update_interval_ticks", visual_environment_update_interval_ticks)))
		_graphics_state.erase("_visual_environment_update_interval_ticks")
	_hud_binding_controller.push_graphics_state(simulation_hud, _graphics_state)

func _push_native_view_metrics() -> void:
	if simulation_controller == null or not simulation_controller.has_method("set_native_view_metrics"):
		return
	simulation_controller.call("set_native_view_metrics", _camera_controller.native_view_metrics())

# Compatibility wrappers retained for existing scene wiring and scripts.
func _screen_to_ground(screen_pos: Vector2) -> Variant:
	return _camera_controller.screen_to_ground(screen_pos)

func _frame_camera_from_environment(environment_snapshot: Dictionary) -> void:
	_camera_controller.frame_from_environment(environment_snapshot)

func _initialize_camera_orbit() -> void:
	_camera_controller.initialize_orbit()

func _rebuild_orbit_state_from_camera() -> void:
	_camera_controller.rebuild_orbit_state_from_camera()

func _handle_camera_mouse_button(event: InputEventMouseButton) -> void:
	_camera_controller.handle_mouse_button(event)

func _handle_camera_mouse_motion(event: InputEventMouseMotion) -> void:
	_camera_controller.handle_mouse_motion(event)

func _orbit_camera(relative: Vector2) -> void:
	_camera_controller.orbit_camera(relative)

func _pan_camera(relative: Vector2) -> void:
	_camera_controller.pan_camera(relative)

func _apply_camera_transform() -> void:
	_camera_controller.apply_camera_transform()
