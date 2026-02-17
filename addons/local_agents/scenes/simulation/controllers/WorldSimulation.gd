extends Node3D
class_name LocalAgentsWorldSimulationController
const FlowTraversalProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowTraversalProfileResource.gd")
const WorldGenConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")
const WorldProgressionProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldProgressionProfileResource.gd")
const AtmosphereCycleControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/AtmosphereCycleController.gd")
const SimulationLoopControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/SimulationLoopController.gd")
const SimulationGraphicsSettingsScript = preload("res://addons/local_agents/scenes/simulation/controllers/SimulationGraphicsSettings.gd")
const WorldCameraControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldCameraController.gd")
const WorldDispatchControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldDispatchController.gd")
const WorldHudBindingControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldHudBindingController.gd")
const WorldEnvironmentSyncControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldEnvironmentSyncController.gd")
const WorldGraphicsTargetWallControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldGraphicsTargetWallController.gd")
const WorldInputControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldInputController.gd")
const FpsLauncherControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/FpsLauncherController.gd")
const WorldNativeVoxelDispatchRuntimeScript = preload("res://addons/local_agents/scenes/simulation/controllers/world/WorldNativeVoxelDispatchRuntime.gd")
const _VOXEL_NATIVE_STAGE_NAME := &"voxel_transform_step"

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
@onready var fps_launcher_controller: Node = get_node_or_null("FpsLauncherController")

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
@export var target_wall_profile_override: Resource
@export var fps_launcher_profile_override: Resource
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
@export_enum("voxel_destruction_only", "full_sim", "lightweight_demo") var runtime_demo_profile: String = "voxel_destruction_only"

var _loop_controller = SimulationLoopControllerScript.new()
var _last_state: Dictionary = {}
var _time_of_day: float = 0.28
var _atmosphere_cycle = AtmosphereCycleControllerScript.new()
var _spawn_mode: String = "none"
var _graphics_state: Dictionary = SimulationGraphicsSettingsScript.default_state()
var _last_hud_refresh_tick: int = -1
var _runtime_profile_baseline: Dictionary = {}
var _runtime_demo_profile_applied: String = ""
var _native_voxel_dispatch_runtime: Dictionary = WorldNativeVoxelDispatchRuntimeScript.default_runtime()
var _system_toggle_state: Dictionary = {
	"transform_stage_a_system_enabled": true,
	"transform_stage_b_system_enabled": true,
	"transform_stage_c_system_enabled": true,
	"transform_stage_d_system_enabled": true,
	"resource_pipeline_enabled": true,
	"structure_lifecycle_enabled": true,
	"culture_cycle_enabled": true,
	"ecology_system_enabled": true,
	"settlement_system_enabled": true,
	"villager_system_enabled": true,
	"cognition_system_enabled": true,
}

var _camera_controller = WorldCameraControllerScript.new()
var _dispatch_controller = WorldDispatchControllerScript.new()
var _hud_binding_controller = WorldHudBindingControllerScript.new()
var _environment_sync_controller = WorldEnvironmentSyncControllerScript.new()
var _graphics_target_wall_controller = WorldGraphicsTargetWallControllerScript.new()
var _input_controller = WorldInputControllerScript.new()
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
	_sync_target_wall_profile(false)

	_camera_controller.configure(world_camera, orbit_sensitivity, pan_sensitivity, zoom_step_ratio, min_zoom_distance, max_zoom_distance, min_pitch_degrees, max_pitch_degrees)
	_dispatch_controller.configure(_VOXEL_NATIVE_STAGE_NAME)
	_environment_sync_controller.configure(environment_controller, world_environment, sun_light, simulation_controller, _ecology_controller, _loop_controller, _atmosphere_cycle)
	_environment_sync_controller.cache_environment_supported_flags()
	if fps_launcher_controller == null:
		fps_launcher_controller = FpsLauncherControllerScript.new()
		fps_launcher_controller.name = "FpsLauncherController"
		add_child(fps_launcher_controller)
	if fps_launcher_controller.has_method("configure"):
		fps_launcher_controller.call("configure", world_camera, self, fps_launcher_profile_override)
	_input_controller.configure(
		self,
		simulation_hud,
		field_hud,
		Callable(self, "_get_spawn_mode"),
		Callable(self, "_set_spawn_mode"),
		Callable(self, "_try_fire_from_screen_center"),
		Callable(self, "_handle_spawn_click"),
		Callable(simulation_hud, "set_mode_label"),
		Callable(_camera_controller, "handle_mouse_motion"),
		Callable(_camera_controller, "handle_mouse_button"),
		camera_controls_enabled
	)
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
		"spawn_mode_requested": Callable(self, "_set_spawn_mode"),
		"spawn_random_requested": Callable(self, "_on_field_spawn_random_requested"),
		"debug_settings_changed": Callable(self, "_on_field_debug_settings_changed")
	}, _spawn_mode)

	_camera_controller.initialize_orbit()
	_on_hud_overlays_changed(false, false, false, false, false, false)
	_apply_runtime_demo_profile(runtime_demo_profile)
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
	var wall_result := _graphics_target_wall_controller.stamp_target_wall(simulation_controller, world_camera, 0, false)
	if bool(wall_result.get("changed", false)):
		setup["environment"] = wall_result.get("environment_snapshot", setup.get("environment", {}))
		setup["network_state_snapshot"] = wall_result.get("network_state_snapshot", setup.get("network_state_snapshot", {}))
	if environment_controller.has_method("apply_generation_data"):
		environment_controller.apply_generation_data(setup.get("environment", {}), setup.get("network_state_snapshot", {}))
	if environment_controller.has_method("set_transform_stage_a_state"):
		environment_controller.set_transform_stage_a_state(setup.get("atmosphere_state_snapshot", {}))
	if environment_controller.has_method("set_transform_stage_d_state"):
		environment_controller.set_transform_stage_d_state(setup.get("exposure_state_snapshot", {}))
	if auto_frame_camera_on_generate:
		_camera_controller.frame_from_environment(setup.get("environment", {}))
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
	WorldNativeVoxelDispatchRuntimeScript.set_fps_mode_active(_native_voxel_dispatch_runtime, _input_controller != null and _input_controller.is_fps_mode())
	if fps_launcher_controller != null and fps_launcher_controller.has_method("step"):
		fps_launcher_controller.call("step", delta)
	var projectile_contact_rows: Array = []
	if fps_launcher_controller != null and fps_launcher_controller.has_method("sample_active_projectile_contact_rows"):
		var rows_variant = fps_launcher_controller.call("sample_active_projectile_contact_rows"); if rows_variant is Array: projectile_contact_rows = rows_variant as Array
	_push_native_view_metrics()
	_process_native_voxel_rate(delta, projectile_contact_rows)
	_apply_loop_result(_loop_controller.process_frame(delta, Callable(self, "_collect_living_entity_profiles"), projectile_contact_rows))
func _unhandled_input(event: InputEvent) -> void:
	if _input_controller != null:
		_input_controller.handle_unhandled_input(event)
func _try_fire_from_screen_center() -> void:
	if _spawn_mode != "none":
		return
	WorldNativeVoxelDispatchRuntimeScript.record_fire_attempt(_native_voxel_dispatch_runtime)
	var fired := false
	if fps_launcher_controller != null and fps_launcher_controller.has_method("try_fire_from_screen_center"):
		fired = bool(fps_launcher_controller.call("try_fire_from_screen_center"))
	WorldNativeVoxelDispatchRuntimeScript.record_fire_result(_native_voxel_dispatch_runtime, fired, Engine.get_process_frames())
func _on_field_spawn_random_requested(plants: int, rabbits: int) -> void:
	if _ecology_controller != null and _ecology_controller.has_method("spawn_random"): _ecology_controller.call("spawn_random", plants, rabbits); _hud_binding_controller.set_field_random_spawn_status(field_hud, plants, rabbits)
func _on_field_debug_settings_changed(settings: Dictionary) -> void:
	if _ecology_controller != null and _ecology_controller.has_method("apply_debug_settings"): _ecology_controller.call("apply_debug_settings", settings)

func _handle_spawn_click(screen_pos: Vector2) -> void:
	if _spawn_mode == "none" or _ecology_controller == null: return
	var point = _camera_controller.screen_to_ground(screen_pos); if point == null: return
	if _spawn_mode == "plant" and _ecology_controller.has_method("spawn_plant_at"):
		_ecology_controller.call("spawn_plant_at", point, 0.0)
	elif _spawn_mode == "rabbit" and _ecology_controller.has_method("spawn_rabbit_at"):
		_ecology_controller.call("spawn_rabbit_at", point)
	_set_spawn_mode("none"); _hud_binding_controller.set_field_selection_restored(field_hud)

func _get_spawn_mode() -> String: return _spawn_mode

func _set_spawn_mode(mode: String) -> void:
	_spawn_mode = String(mode).strip_edges()
	_spawn_mode = "none" if _spawn_mode == "" else _spawn_mode
	_hud_binding_controller.set_field_spawn_mode(field_hud, _spawn_mode)

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
	_graphics_state = _graphics_target_wall_controller.apply_hud_graphics_option(
		_graphics_state,
		option_id,
		value,
		_environment_sync_controller
	)
	var restamp_target_wall := _graphics_target_wall_controller.is_target_wall_graphics_option(option_id)
	_apply_graphics_state(restamp_target_wall)

func set_runtime_demo_profile(profile_id: String) -> void:
	_apply_runtime_demo_profile(profile_id)

func runtime_demo_profile_id() -> String:
	return _runtime_demo_profile_applied if _runtime_demo_profile_applied != "" else _sanitize_runtime_demo_profile(runtime_demo_profile)

func _apply_graphics_state(restamp_target_wall: bool = false) -> void:
	_graphics_state = _graphics_target_wall_controller.apply_graphics_state(
		_graphics_state,
		_environment_sync_controller,
		simulation_ticks_per_second,
		living_profile_push_interval_ticks
	)
	_apply_runtime_system_toggles()
	var interval_payload := _graphics_target_wall_controller.consume_visual_environment_interval(
		_graphics_state,
		visual_environment_update_interval_ticks
	)
	var graphics_state_variant = interval_payload.get("graphics_state", _graphics_state)
	if graphics_state_variant is Dictionary:
		_graphics_state = (graphics_state_variant as Dictionary).duplicate(true)
	visual_environment_update_interval_ticks = maxi(1, int(interval_payload.get("visual_environment_update_interval_ticks", visual_environment_update_interval_ticks)))
	_sync_target_wall_profile(restamp_target_wall)
	_hud_binding_controller.push_graphics_state(simulation_hud, _graphics_state)

func _sync_target_wall_profile(restamp_target_wall: bool) -> void:
	var profile_payload := _graphics_target_wall_controller.sync_target_wall_profile(
		target_wall_profile_override,
		_graphics_state,
		simulation_controller
	)
	var profile_variant = profile_payload.get("profile", target_wall_profile_override)
	if profile_variant is Resource:
		target_wall_profile_override = profile_variant as Resource
	if restamp_target_wall and bool(profile_payload.get("profile_changed", false)):
		var tick := _loop_controller.current_tick() if _loop_controller != null else 0
		_apply_target_wall_restamp_result(_graphics_target_wall_controller.stamp_target_wall(simulation_controller, world_camera, tick, false), tick)

func _apply_target_wall_restamp_result(wall_result: Dictionary, tick: int) -> void:
	if wall_result.is_empty() or not bool(wall_result.get("changed", false)):
		return
	_sync_environment_from_state({
		"tick": tick,
		"environment_snapshot": wall_result.get("environment_snapshot", simulation_controller.current_environment_snapshot() if simulation_controller.has_method("current_environment_snapshot") else {}),
		"network_state_snapshot": wall_result.get("network_state_snapshot", simulation_controller.current_network_state_snapshot() if simulation_controller.has_method("current_network_state_snapshot") else {}),
		"atmosphere_state_snapshot": simulation_controller.call("get_atmosphere_state_snapshot") if simulation_controller.has_method("get_atmosphere_state_snapshot") else {},
		"deformation_state_snapshot": simulation_controller.call("get_deformation_state_snapshot") if simulation_controller.has_method("get_deformation_state_snapshot") else {},
		"exposure_state_snapshot": simulation_controller.call("get_exposure_state_snapshot") if simulation_controller.has_method("get_exposure_state_snapshot") else {},
		"transform_changed": true,
		"transform_changed_tiles": (wall_result.get("changed_tiles", []) as Array).duplicate(true),
		"transform_changed_chunks": (wall_result.get("changed_chunks", []) as Array).duplicate(true),
	}, false)

func _apply_runtime_system_toggles() -> void:
	var transform_stage_a_system_enabled: bool = bool(_graphics_state.get("transform_stage_a_system_enabled", true))
	var transform_stage_b_system_enabled: bool = bool(_graphics_state.get("transform_stage_b_system_enabled", true))
	var transform_stage_c_system_enabled: bool = bool(_graphics_state.get("transform_stage_c_system_enabled", true))
	var transform_stage_d_system_enabled: bool = bool(_graphics_state.get("transform_stage_d_system_enabled", true))
	var resource_pipeline_enabled: bool = bool(_graphics_state.get("resource_pipeline_enabled", true))
	var structure_lifecycle_enabled: bool = bool(_graphics_state.get("structure_lifecycle_enabled", true))
	var culture_cycle_enabled: bool = bool(_graphics_state.get("culture_cycle_enabled", true))
	var ecology_system_enabled: bool = bool(_graphics_state.get("ecology_system_enabled", true))
	var settlement_system_enabled: bool = bool(_graphics_state.get("settlement_system_enabled", true))
	var villager_system_enabled: bool = bool(_graphics_state.get("villager_system_enabled", true))
	var cognition_system_enabled: bool = bool(_graphics_state.get("cognition_system_enabled", true))

	if simulation_controller != null:
		if simulation_controller.has_method("set_transform_stage_system_enabled"):
			simulation_controller.call("set_transform_stage_system_enabled", "stage_a", transform_stage_a_system_enabled)
		else:
			simulation_controller.set("transform_stage_a_system_enabled", transform_stage_a_system_enabled)
		if simulation_controller.has_method("set_transform_stage_system_enabled"):
			simulation_controller.call("set_transform_stage_system_enabled", "stage_b", transform_stage_b_system_enabled)
		else:
			simulation_controller.set("transform_stage_b_system_enabled", transform_stage_b_system_enabled)
		if simulation_controller.has_method("set_transform_stage_system_enabled"):
			simulation_controller.call("set_transform_stage_system_enabled", "stage_c", transform_stage_c_system_enabled)
		else:
			simulation_controller.set("transform_stage_c_system_enabled", transform_stage_c_system_enabled)
		if simulation_controller.has_method("set_transform_stage_system_enabled"):
			simulation_controller.call("set_transform_stage_system_enabled", "stage_d", transform_stage_d_system_enabled)
		else:
			simulation_controller.set("transform_stage_d_system_enabled", transform_stage_d_system_enabled)
		if simulation_controller.has_method("set_resource_pipeline_enabled"):
			simulation_controller.call("set_resource_pipeline_enabled", resource_pipeline_enabled)
		else:
			simulation_controller.set("resource_pipeline_enabled", resource_pipeline_enabled)
		if simulation_controller.has_method("set_structure_lifecycle_enabled"):
			simulation_controller.call("set_structure_lifecycle_enabled", structure_lifecycle_enabled)
		else:
			simulation_controller.set("structure_lifecycle_enabled", structure_lifecycle_enabled)
		if simulation_controller.has_method("set_culture_system_enabled"):
			simulation_controller.call("set_culture_system_enabled", culture_cycle_enabled)
		else:
			simulation_controller.set("culture_system_enabled", culture_cycle_enabled)
		if simulation_controller.has_method("set_ecology_system_enabled"):
			simulation_controller.call("set_ecology_system_enabled", ecology_system_enabled)
		else:
			simulation_controller.set("ecology_system_enabled", ecology_system_enabled)
		if simulation_controller.has_method("set_cognition_system_enabled"):
			simulation_controller.call("set_cognition_system_enabled", cognition_system_enabled)
		else:
			simulation_controller.set("cognition_system_enabled", cognition_system_enabled)

	_update_node_system_runtime(
		"settlement_system_enabled",
		settlement_system_enabled,
		settlement_controller,
		true,
		true,
		true
	)
	_update_node_system_runtime(
		"villager_system_enabled",
		villager_system_enabled,
		villager_controller,
		true,
		true,
		true
	)
	_update_node_system_runtime(
		"culture_cycle_enabled",
		culture_cycle_enabled,
		culture_controller,
		true,
		true,
		true
	)
	_update_ecology_system_runtime(ecology_system_enabled)

func _update_node_system_runtime(
	state_key: String,
	enabled: bool,
	node: Node,
	set_visible: bool,
	set_processing: bool,
	clear_on_disable: bool
) -> void:
	var previously_enabled := bool(_system_toggle_state.get(state_key, true))
	if not (node is Node):
		_system_toggle_state[state_key] = enabled
		return
	if node == null:
		_system_toggle_state[state_key] = enabled
		return
	if set_processing and node.has_method("set_process"):
		node.set_process(enabled)
	if set_processing and node.has_method("set_physics_process"):
		node.set_physics_process(enabled)
	if set_visible and node is Node3D:
		(node as Node3D).visible = enabled
	if clear_on_disable and previously_enabled and not enabled and node.has_method("clear_generated"):
		node.call("clear_generated")
	_system_toggle_state[state_key] = enabled

func _update_ecology_system_runtime(enabled: bool) -> void:
	var previously_enabled := bool(_system_toggle_state.get("ecology_system_enabled", true))
	if _ecology_controller == null:
		_system_toggle_state["ecology_system_enabled"] = enabled
		return
	if _ecology_controller.has_method("set_process"):
		_ecology_controller.set_process(enabled)
	if _ecology_controller.has_method("set_physics_process"):
		_ecology_controller.set_physics_process(enabled)
	if _ecology_controller is Node3D:
		(_ecology_controller as Node3D).visible = enabled

	var smell_enabled := bool(_graphics_state.get("smell_gpu_compute_enabled", false))
	var wind_enabled := bool(_graphics_state.get("wind_gpu_compute_enabled", false))
	var voxel_gate_smell_enabled := bool(_graphics_state.get("voxel_gate_smell_enabled", true))
	var voxel_gate_plants_enabled := bool(_graphics_state.get("voxel_gate_plants_enabled", true))
	var voxel_gate_mammals_enabled := bool(_graphics_state.get("voxel_gate_mammals_enabled", true))
	var voxel_gate_shelter_enabled := bool(_graphics_state.get("voxel_gate_shelter_enabled", true))
	var voxel_gate_profile_refresh_enabled := bool(_graphics_state.get("voxel_gate_profile_refresh_enabled", true))
	var voxel_gate_edible_index_enabled := bool(_graphics_state.get("voxel_gate_edible_index_enabled", true))

	if enabled:
		if _ecology_controller.has_method("set_smell_gpu_compute_enabled"):
			_ecology_controller.call("set_smell_gpu_compute_enabled", smell_enabled)
		else:
			_ecology_controller.set("smell_gpu_compute_enabled", smell_enabled)
		if _ecology_controller.has_method("set_wind_gpu_compute_enabled"):
			_ecology_controller.call("set_wind_gpu_compute_enabled", wind_enabled)
		else:
			_ecology_controller.set("wind_gpu_compute_enabled", wind_enabled)
		_set_node_property_if_exists(_ecology_controller, "voxel_gate_smell_enabled", voxel_gate_smell_enabled)
		_set_node_property_if_exists(_ecology_controller, "voxel_gate_plants_enabled", voxel_gate_plants_enabled)
		_set_node_property_if_exists(_ecology_controller, "voxel_gate_mammals_enabled", voxel_gate_mammals_enabled)
		_set_node_property_if_exists(_ecology_controller, "voxel_gate_shelter_enabled", voxel_gate_shelter_enabled)
		_set_node_property_if_exists(_ecology_controller, "voxel_gate_profile_refresh_enabled", voxel_gate_profile_refresh_enabled)
		_set_node_property_if_exists(_ecology_controller, "voxel_gate_edible_index_enabled", voxel_gate_edible_index_enabled)
	else:
		if _ecology_controller.has_method("set_smell_gpu_compute_enabled"):
			_ecology_controller.call("set_smell_gpu_compute_enabled", false)
		else:
			_ecology_controller.set("smell_gpu_compute_enabled", false)
		if _ecology_controller.has_method("set_wind_gpu_compute_enabled"):
			_ecology_controller.call("set_wind_gpu_compute_enabled", false)
		else:
			_ecology_controller.set("wind_gpu_compute_enabled", false)
		_set_node_property_if_exists(_ecology_controller, "voxel_gate_smell_enabled", false)
		_set_node_property_if_exists(_ecology_controller, "voxel_gate_plants_enabled", false)
		_set_node_property_if_exists(_ecology_controller, "voxel_gate_mammals_enabled", false)
		_set_node_property_if_exists(_ecology_controller, "voxel_gate_shelter_enabled", false)
		_set_node_property_if_exists(_ecology_controller, "voxel_gate_profile_refresh_enabled", false)
		_set_node_property_if_exists(_ecology_controller, "voxel_gate_edible_index_enabled", false)
		if previously_enabled and not enabled and _ecology_controller.has_method("clear_generated"):
			_ecology_controller.call("clear_generated")
	_system_toggle_state["ecology_system_enabled"] = enabled

func _set_node_property_if_exists(node: Object, property_name: String, value) -> void:
	if node == null:
		return
	var has_property := false
	for property in node.get_property_list():
		if String(property.get("name", "")) == property_name:
			has_property = true
			break
	if has_property:
		node.set(property_name, value)

func _process_native_voxel_rate(delta: float, projectile_contact_rows: Array = []) -> void:
	_dispatch_controller.process_native_voxel_rate(delta, projectile_contact_rows, {
		"tick": _loop_controller.current_tick(),
		"frame_index": Engine.get_process_frames(),
		"simulation_controller": simulation_controller,
		"fps_launcher_controller": fps_launcher_controller,
		"camera_controller": _camera_controller,
		"graphics_target_wall_controller": _graphics_target_wall_controller,
		"native_voxel_dispatch_runtime": _native_voxel_dispatch_runtime,
		"sync_environment_from_state": Callable(self, "_sync_environment_from_state").bind(false),
	})

func native_voxel_dispatch_runtime() -> Dictionary:
	return _native_voxel_dispatch_runtime.duplicate(true)

func _apply_runtime_demo_profile(profile_id: String) -> void:
	_capture_runtime_profile_baseline_if_needed()
	var sanitized_profile := _sanitize_runtime_demo_profile(profile_id)
	_restore_runtime_profile_baseline()
	var profile_settings := _runtime_profile_settings(sanitized_profile)
	var controller_settings_variant = profile_settings.get("controller", {})
	if controller_settings_variant is Dictionary:
		_apply_runtime_controller_settings(controller_settings_variant as Dictionary)
	var graphics_settings_variant = profile_settings.get("graphics", {})
	if graphics_settings_variant is Dictionary:
		_apply_runtime_graphics_settings(graphics_settings_variant as Dictionary)
	runtime_demo_profile = sanitized_profile
	_runtime_demo_profile_applied = sanitized_profile
	_apply_graphics_state()

func _capture_runtime_profile_baseline_if_needed() -> void:
	if not _runtime_profile_baseline.is_empty():
		return
	_runtime_profile_baseline = {
		"simulation_ticks_per_second": simulation_ticks_per_second,
		"living_profile_push_interval_ticks": living_profile_push_interval_ticks,
		"visual_environment_update_interval_ticks": visual_environment_update_interval_ticks,
		"hud_refresh_interval_ticks": hud_refresh_interval_ticks,
		"day_night_cycle_enabled": day_night_cycle_enabled,
		"graphics_state": SimulationGraphicsSettingsScript.merge_with_defaults(_graphics_state).duplicate(true),
	}

func _restore_runtime_profile_baseline() -> void:
	if _runtime_profile_baseline.is_empty():
		return
	simulation_ticks_per_second = float(_runtime_profile_baseline.get("simulation_ticks_per_second", simulation_ticks_per_second))
	living_profile_push_interval_ticks = maxi(1, int(_runtime_profile_baseline.get("living_profile_push_interval_ticks", living_profile_push_interval_ticks)))
	visual_environment_update_interval_ticks = maxi(1, int(_runtime_profile_baseline.get("visual_environment_update_interval_ticks", visual_environment_update_interval_ticks)))
	hud_refresh_interval_ticks = maxi(1, int(_runtime_profile_baseline.get("hud_refresh_interval_ticks", hud_refresh_interval_ticks)))
	day_night_cycle_enabled = bool(_runtime_profile_baseline.get("day_night_cycle_enabled", day_night_cycle_enabled))
	var baseline_graphics_variant = _runtime_profile_baseline.get("graphics_state", {})
	if baseline_graphics_variant is Dictionary:
		_graphics_state = (baseline_graphics_variant as Dictionary).duplicate(true)
	else:
		_graphics_state = SimulationGraphicsSettingsScript.default_state()

func _apply_runtime_controller_settings(settings: Dictionary) -> void:
	if settings.has("simulation_ticks_per_second"):
		simulation_ticks_per_second = clampf(float(settings.get("simulation_ticks_per_second")), 0.5, 30.0)
	if settings.has("living_profile_push_interval_ticks"):
		living_profile_push_interval_ticks = maxi(1, int(settings.get("living_profile_push_interval_ticks")))
	if settings.has("visual_environment_update_interval_ticks"):
		visual_environment_update_interval_ticks = maxi(1, int(settings.get("visual_environment_update_interval_ticks")))
	if settings.has("hud_refresh_interval_ticks"):
		hud_refresh_interval_ticks = maxi(1, int(settings.get("hud_refresh_interval_ticks")))
	if settings.has("day_night_cycle_enabled"):
		day_night_cycle_enabled = bool(settings.get("day_night_cycle_enabled"))

func _apply_runtime_graphics_settings(settings: Dictionary) -> void:
	for key_variant in settings.keys():
		var key := String(key_variant)
		_graphics_state[key] = _environment_sync_controller.sanitize_graphics_value(key, settings.get(key_variant))

func _sanitize_runtime_demo_profile(profile_id: String) -> String:
	var normalized := String(profile_id).strip_edges().to_lower()
	if normalized in ["full_sim", "voxel_destruction_only", "lightweight_demo"]:
		return normalized
	return "voxel_destruction_only"

func _runtime_profile_settings(profile_id: String) -> Dictionary:
	match profile_id:
		"voxel_destruction_only":
			return {
				"controller": {
					"simulation_ticks_per_second": 4.0,
					"living_profile_push_interval_ticks": 4,
					"visual_environment_update_interval_ticks": 2,
					"hud_refresh_interval_ticks": 1,
					"day_night_cycle_enabled": false,
				},
				"graphics": {
					"transform_stage_a_system_enabled": false,
					"transform_stage_b_system_enabled": false,
					"transform_stage_c_system_enabled": true,
					"transform_stage_d_system_enabled": false,
					"resource_pipeline_enabled": false,
					"structure_lifecycle_enabled": false,
					"culture_cycle_enabled": false,
					"ecology_system_enabled": false,
					"settlement_system_enabled": false,
					"villager_system_enabled": false,
					"cognition_system_enabled": false,
					"smell_gpu_compute_enabled": false,
					"wind_gpu_compute_enabled": false,
					"voxel_gate_smell_enabled": false,
					"voxel_gate_plants_enabled": false,
					"voxel_gate_mammals_enabled": false,
					"voxel_gate_shelter_enabled": false,
					"voxel_gate_profile_refresh_enabled": false,
					"voxel_gate_edible_index_enabled": false,
					"voxel_process_gating_enabled": true,
					"voxel_dynamic_tick_rate_enabled": true,
					"voxel_tick_min_interval_seconds": 0.12,
					"voxel_tick_max_interval_seconds": 0.9,
				},
			}
		"full_sim":
			return {
				"controller": {
					"simulation_ticks_per_second": 4.0,
					"living_profile_push_interval_ticks": 4,
					"visual_environment_update_interval_ticks": 2,
					"hud_refresh_interval_ticks": 1,
					"day_night_cycle_enabled": true,
				},
				"graphics": {
					"water_shader_enabled": true,
					"ocean_surface_enabled": true,
					"river_overlays_enabled": true,
					"rain_post_fx_enabled": true,
					"clouds_enabled": true,
					"cloud_quality": "medium",
					"cloud_density_scale": 0.6,
					"rain_visual_intensity_scale": 0.65,
					"shadows_enabled": true,
					"ssao_enabled": true,
					"glow_enabled": true,
					"simulation_rate_override_enabled": false,
					"simulation_locality_enabled": false,
					"transform_stage_a_solver_decimation_enabled": false,
					"transform_stage_b_solver_decimation_enabled": false,
					"transform_stage_c_solver_decimation_enabled": false,
					"transform_stage_d_solver_decimation_enabled": false,
					"resource_pipeline_decimation_enabled": false,
					"structure_lifecycle_decimation_enabled": false,
					"culture_cycle_decimation_enabled": false,
					"ecology_step_decimation_enabled": false,
				},
			}
		"lightweight_demo":
			return {
				"controller": {
					"simulation_ticks_per_second": 4.0,
					"living_profile_push_interval_ticks": 8,
					"visual_environment_update_interval_ticks": 8,
					"hud_refresh_interval_ticks": 4,
					"day_night_cycle_enabled": false,
				},
				"graphics": {
					"water_shader_enabled": false,
					"ocean_surface_enabled": false,
					"river_overlays_enabled": false,
					"rain_post_fx_enabled": false,
					"clouds_enabled": false,
					"shadows_enabled": false,
					"ssr_enabled": false,
					"ssao_enabled": false,
					"ssil_enabled": false,
					"sdfgi_enabled": false,
					"glow_enabled": false,
					"fog_enabled": false,
					"volumetric_fog_enabled": false,
					"simulation_rate_override_enabled": true,
					"simulation_ticks_per_second_override": 2.0,
					"simulation_locality_enabled": true,
					"simulation_locality_dynamic_enabled": true,
					"simulation_locality_radius_tiles": 1,
					"transform_stage_a_solver_decimation_enabled": true,
					"transform_stage_b_solver_decimation_enabled": true,
					"transform_stage_c_solver_decimation_enabled": true,
					"transform_stage_d_solver_decimation_enabled": true,
					"resource_pipeline_decimation_enabled": true,
					"structure_lifecycle_decimation_enabled": true,
					"culture_cycle_decimation_enabled": true,
					"transform_stage_a_texture_upload_decimation_enabled": true,
					"transform_stage_b_texture_upload_decimation_enabled": true,
					"transform_stage_d_texture_upload_decimation_enabled": true,
					"texture_upload_interval_ticks": 12,
					"texture_upload_budget_texels": 2048,
					"ecology_step_decimation_enabled": true,
					"ecology_step_interval_seconds": 0.35,
					"smell_gpu_compute_enabled": false,
					"wind_gpu_compute_enabled": false,
					"voxel_process_gating_enabled": true,
					"voxel_dynamic_tick_rate_enabled": true,
					"voxel_tick_min_interval_seconds": 0.12,
					"voxel_tick_max_interval_seconds": 0.9,
				},
			}
		_: 
			return {
				"graphics": {
					"transform_stage_a_system_enabled": false,
					"transform_stage_b_system_enabled": false,
					"transform_stage_c_system_enabled": false,
					"transform_stage_d_system_enabled": false,
					"resource_pipeline_enabled": false,
					"structure_lifecycle_enabled": false,
					"culture_cycle_enabled": false,
					"ecology_system_enabled": false,
					"settlement_system_enabled": false,
					"villager_system_enabled": false,
					"cognition_system_enabled": false,
					"simulation_rate_override_enabled": true,
					"simulation_ticks_per_second_override": 2.0,
				},
			}

func _push_native_view_metrics() -> void:
	if simulation_controller == null or not simulation_controller.has_method("set_native_view_metrics"):
		return
	simulation_controller.call("set_native_view_metrics", _camera_controller.native_view_metrics())
