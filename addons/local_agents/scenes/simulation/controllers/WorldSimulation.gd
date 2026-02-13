extends Node3D
class_name LocalAgentsWorldSimulationController

const FlowTraversalProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowTraversalProfileResource.gd")
const WorldGenConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldGenConfigResource.gd")
const WorldProgressionProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/WorldProgressionProfileResource.gd")
const EnvironmentSignalSnapshotResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/EnvironmentSignalSnapshotResource.gd")
const AtmosphereCycleControllerScript = preload("res://addons/local_agents/scenes/simulation/controllers/AtmosphereCycleController.gd")

@onready var simulation_controller: Node = $SimulationController
@onready var environment_controller: Node3D = $EnvironmentController
@onready var settlement_controller: Node3D = $SettlementController
@onready var villager_controller: Node3D = $VillagerController
@onready var culture_controller: Node3D = $CultureController
@onready var debug_overlay_root: Node3D = $DebugOverlayRoot
@onready var simulation_hud: CanvasLayer = $SimulationHud
@onready var sun_light: DirectionalLight3D = $DirectionalLight3D
@onready var world_environment: WorldEnvironment = $WorldEnvironment
@export var world_seed_text: String = "world_progression_main"
@export var auto_generate_on_ready: bool = true
@export var auto_play_on_ready: bool = true
@export var flow_traversal_profile_override: Resource
@export var worldgen_config_override: Resource
@export var world_progression_profile_override: Resource
@export var start_year: float = -8000.0
@export var years_per_tick: float = 0.25
@export var start_simulated_seconds: float = 0.0
@export var simulated_seconds_per_tick: float = 1.0
@export var day_night_cycle_enabled: bool = true
@export var day_length_seconds: float = 180.0
@export_range(0.0, 1.0, 0.001) var start_time_of_day: float = 0.28

var _is_playing: bool = false
var _ticks_per_frame: int = 1
var _current_tick: int = 0
var _fork_index: int = 0
var _last_state: Dictionary = {}
var _time_of_day: float = 0.28
var _simulated_seconds: float = 0.0
var _atmosphere_cycle = AtmosphereCycleControllerScript.new()

func _ready() -> void:
	_time_of_day = clampf(start_time_of_day, 0.0, 1.0)
	_simulated_seconds = maxf(0.0, start_simulated_seconds)
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
	if has_node("EcologyController"):
		var ecology_controller = get_node("EcologyController")
		if ecology_controller.has_method("set_debug_overlay"):
			ecology_controller.call("set_debug_overlay", debug_overlay_root)
	if not auto_generate_on_ready:
		return
	if simulation_controller.has_method("configure"):
		simulation_controller.configure(world_seed_text, false, false)
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
	_apply_environment_signals(_build_environment_signal_snapshot_from_setup(setup, 0))
	if settlement_controller.has_method("spawn_initial_settlement"):
		settlement_controller.spawn_initial_settlement(setup.get("spawn", {}))
	_current_tick = 0
	_simulated_seconds = _seconds_at_tick(_current_tick)
	_is_playing = auto_play_on_ready
	if simulation_controller.has_method("current_snapshot"):
		_last_state = simulation_controller.current_snapshot(0)
		_last_state["simulated_year"] = _year_at_tick(0)
		_last_state["simulated_seconds"] = _simulated_seconds
		_sync_environment_from_state(_last_state, false)
	_refresh_hud()

func _process(_delta: float) -> void:
	_update_day_night(_delta)
	if not _is_playing:
		return
	for _i in range(_ticks_per_frame):
		_advance_tick()
	_refresh_hud()

func _advance_tick() -> void:
	if not simulation_controller.has_method("process_tick"):
		return
	if has_node("EcologyController"):
		var ecology_controller = get_node("EcologyController")
		if ecology_controller.has_method("collect_living_entity_profiles") and simulation_controller.has_method("set_living_entity_profiles"):
			simulation_controller.call("set_living_entity_profiles", ecology_controller.call("collect_living_entity_profiles"))
	var next_tick = _current_tick + 1
	var result: Dictionary = simulation_controller.process_tick(next_tick, 1.0)
	if bool(result.get("ok", false)):
		_current_tick = next_tick
		_simulated_seconds = _seconds_at_tick(_current_tick)
		_last_state = result.get("state", {}).duplicate(true)
		_last_state["simulated_year"] = _year_at_tick(_current_tick)
		_last_state["simulated_seconds"] = _simulated_seconds
		_sync_environment_from_state(_last_state, false)

func _sync_environment_from_state(state: Dictionary, force_rebuild: bool) -> void:
	if environment_controller == null:
		return
	if state.is_empty():
		return
	var env_signals = _build_environment_signal_snapshot_from_state(state)
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
	if environment_controller.has_method("set_weather_state"):
		environment_controller.set_weather_state(env_signals.weather_snapshot)
	if environment_controller.has_method("set_solar_state"):
		environment_controller.set_solar_state(env_signals.solar_snapshot)
	_apply_environment_signals(env_signals)

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
	if not simulation_controller.has_method("restore_to_tick"):
		return
	var target_tick = maxi(0, _current_tick - 24)
	var restored: Dictionary = simulation_controller.restore_to_tick(target_tick)
	if bool(restored.get("ok", false)):
		_current_tick = int(restored.get("tick", target_tick))
		_simulated_seconds = _seconds_at_tick(_current_tick)
		if simulation_controller.has_method("current_snapshot"):
			_last_state = simulation_controller.current_snapshot(_current_tick)
			_last_state["simulated_year"] = _year_at_tick(_current_tick)
			_last_state["simulated_seconds"] = _simulated_seconds
			_sync_environment_from_state(_last_state, true)
	_refresh_hud()

func _on_hud_fork_pressed() -> void:
	if not simulation_controller.has_method("fork_branch"):
		return
	_fork_index += 1
	var new_branch = "branch_%02d" % _fork_index
	var forked: Dictionary = simulation_controller.fork_branch(new_branch, _current_tick)
	if bool(forked.get("ok", false)):
		if simulation_controller.has_method("current_snapshot"):
			_last_state = simulation_controller.current_snapshot(_current_tick)
			_last_state["simulated_year"] = _year_at_tick(_current_tick)
			_last_state["simulated_seconds"] = _simulated_seconds
			_sync_environment_from_state(_last_state, true)
	_refresh_hud()

func _refresh_hud() -> void:
	if simulation_hud == null:
		return
	var branch_id = "main"
	if simulation_controller.has_method("get_active_branch_id"):
		branch_id = String(simulation_controller.get_active_branch_id())
	var mode = "playing" if _is_playing else "paused"
	var year = _year_at_tick(_current_tick)
	var time_text = _format_duration_hms(_simulated_seconds)
	simulation_hud.set_status_text("Year %.1f | T+%s | Tick %d | Branch %s | %s x%d" % [year, time_text, _current_tick, branch_id, mode, _ticks_per_frame])

	var structures = 0
	var oral_events = int((_last_state.get("oral_transfer_events", []) as Array).size())
	var ritual_events = int((_last_state.get("ritual_events", []) as Array).size())
	var structures_by_household: Dictionary = _last_state.get("structures", {})
	for household_id in structures_by_household.keys():
		structures += int((structures_by_household.get(household_id, []) as Array).size())

	var belief_conflicts = _active_belief_conflicts(_current_tick)
	var detail_lines: Array[String] = []
	detail_lines.append("Structures: %d | Oral events: %d | Ritual events: %d | Belief conflicts: %d" % [structures, oral_events, ritual_events, belief_conflicts])
	if branch_id != "main" and simulation_controller.has_method("branch_diff"):
		var diff: Dictionary = simulation_controller.branch_diff("main", branch_id, maxi(0, _current_tick - 48), _current_tick)
		if bool(diff.get("ok", false)):
			var pop_delta = int(diff.get("population_delta", 0))
			var belief_delta = int(diff.get("belief_divergence", 0))
			var culture_delta = float(diff.get("culture_continuity_score_delta", 0.0))
			detail_lines.append("Diff vs main: pop %+d | belief %+d | culture %+0.3f" % [pop_delta, belief_delta, culture_delta])
	var details_text = "\n".join(detail_lines)
	if simulation_hud.has_method("set_details_text"):
		simulation_hud.set_details_text(details_text)

func _active_belief_conflicts(tick: int) -> int:
	if not simulation_controller.has_method("get_backstory_service"):
		return 0
	var service = simulation_controller.get_backstory_service()
	if service == null:
		return 0
	var villagers: Dictionary = _last_state.get("villagers", {})
	var ids = villagers.keys()
	ids.sort_custom(func(a, b): return String(a) < String(b))
	if ids.is_empty():
		return 0
	var npc_id = String(ids[0])
	var world_day = int(tick / 24)
	var result: Dictionary = service.get_belief_truth_conflicts(npc_id, world_day, 8)
	if not bool(result.get("ok", false)):
		return 0
	return int((result.get("conflicts", []) as Array).size())

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
		snapshot.tick = int(state.get("tick", _current_tick))
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
	var weather: Dictionary = _last_state.get("weather_snapshot", {})
	var humidity = clampf(float(weather.get("avg_humidity", 0.0)), 0.0, 1.0)
	var rain = clampf(float(weather.get("avg_rain_intensity", 0.0)), 0.0, 1.0)
	var cloud = clampf(float(weather.get("avg_cloud_cover", 0.0)), 0.0, 1.0)
	var fog_target = clampf(humidity * 0.45 + rain * 0.35 + cloud * 0.2, 0.0, 1.0)
	var night_boost = 1.0 - daylight
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = lerpf(0.015, 0.08, clampf(fog_target * 0.78 + night_boost * 0.22, 0.0, 1.0))
	env.volumetric_fog_emission_energy = lerpf(0.35, 0.9, daylight)
	env.volumetric_fog_albedo = Color(
		lerpf(0.26, 0.74, daylight),
		lerpf(0.3, 0.78, daylight),
		lerpf(0.36, 0.84, daylight),
		1.0
	)

func _year_at_tick(tick: int) -> float:
	return start_year + float(tick) * years_per_tick

func _seconds_at_tick(tick: int) -> float:
	return maxf(0.0, start_simulated_seconds + float(tick) * maxf(0.0001, simulated_seconds_per_tick))

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
