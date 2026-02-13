extends RefCounted
class_name LocalAgentsWorldEnvironmentSyncController

const EnvironmentSignalSnapshotResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/EnvironmentSignalSnapshotResource.gd")
const SimulationGraphicsSettingsScript = preload("res://addons/local_agents/scenes/simulation/controllers/SimulationGraphicsSettings.gd")

var _environment_controller: Node3D = null
var _world_environment: WorldEnvironment = null
var _sun_light: DirectionalLight3D = null
var _simulation_controller: Node = null
var _ecology_controller: Node = null
var _loop_controller = null
var _atmosphere_cycle = null
var _supported_environment_flags: Dictionary = {}
var _last_fog_enabled: bool = false
var _last_volumetric_fog_enabled: bool = false

func configure(
	environment_controller: Node3D,
	world_environment: WorldEnvironment,
	sun_light: DirectionalLight3D,
	simulation_controller: Node,
	ecology_controller: Node,
	loop_controller,
	atmosphere_cycle
) -> void:
	_environment_controller = environment_controller
	_world_environment = world_environment
	_sun_light = sun_light
	_simulation_controller = simulation_controller
	_ecology_controller = ecology_controller
	_loop_controller = loop_controller
	_atmosphere_cycle = atmosphere_cycle

func cache_environment_supported_flags() -> void:
	_supported_environment_flags.clear()
	if _world_environment == null or _world_environment.environment == null:
		return
	var env: Environment = _world_environment.environment
	for prop in env.get_property_list():
		var name = String((prop as Dictionary).get("name", ""))
		if name != "":
			_supported_environment_flags[name] = true

func build_snapshot_from_setup(setup: Dictionary, tick: int):
	var snapshot = EnvironmentSignalSnapshotResourceScript.new()
	snapshot.tick = tick
	snapshot.environment_snapshot = setup.get("environment", {}).duplicate(true)
	snapshot.water_network_snapshot = setup.get("hydrology", {}).duplicate(true)
	snapshot.weather_snapshot = setup.get("weather", {}).duplicate(true)
	snapshot.erosion_snapshot = setup.get("erosion", {}).duplicate(true)
	snapshot.solar_snapshot = setup.get("solar", {}).duplicate(true)
	return snapshot

func build_snapshot_from_state(state: Dictionary, fallback_tick: int):
	var snapshot = EnvironmentSignalSnapshotResourceScript.new()
	var signals_variant = state.get("environment_signals", {})
	if signals_variant is Dictionary:
		snapshot.from_dict(signals_variant as Dictionary)
	else:
		snapshot.tick = int(state.get("tick", fallback_tick))
		snapshot.environment_snapshot = state.get("environment_snapshot", {}).duplicate(true)
		snapshot.water_network_snapshot = state.get("water_network_snapshot", {}).duplicate(true)
		snapshot.weather_snapshot = state.get("weather_snapshot", {}).duplicate(true)
		snapshot.erosion_snapshot = state.get("erosion_snapshot", {}).duplicate(true)
		snapshot.solar_snapshot = state.get("solar_snapshot", {}).duplicate(true)
		snapshot.erosion_changed = bool(state.get("erosion_changed", false))
		snapshot.erosion_changed_tiles = (state.get("erosion_changed_tiles", []) as Array).duplicate(true)
	return snapshot

func apply_environment_signals(snapshot) -> void:
	if _ecology_controller != null and _ecology_controller.has_method("set_environment_signals"):
		_ecology_controller.call("set_environment_signals", snapshot)

func sync_from_state(state: Dictionary, force_rebuild: bool, visual_interval_ticks: int) -> void:
	if _environment_controller == null or state.is_empty():
		return
	var env_signals = build_snapshot_from_state(state, _loop_controller.current_tick())
	var tick = _loop_controller.current_tick()
	var do_visual_update: bool = force_rebuild or (tick % maxi(1, visual_interval_ticks) == 0)
	if force_rebuild or bool(env_signals.erosion_changed):
		if not force_rebuild and _environment_controller.has_method("apply_generation_delta"):
			_environment_controller.apply_generation_delta(
				env_signals.environment_snapshot,
				env_signals.water_network_snapshot,
				env_signals.erosion_changed_tiles
			)
		elif _environment_controller.has_method("apply_generation_data"):
			_environment_controller.apply_generation_data(
				env_signals.environment_snapshot,
				env_signals.water_network_snapshot
			)
	if do_visual_update and _environment_controller.has_method("set_weather_state"):
		_environment_controller.set_weather_state(env_signals.weather_snapshot)
	if do_visual_update and _environment_controller.has_method("set_solar_state"):
		_environment_controller.set_solar_state(env_signals.solar_snapshot)
	apply_environment_signals(env_signals)

func update_day_night(
	delta: float,
	time_of_day: float,
	day_night_cycle_enabled: bool,
	day_length_seconds: float,
	graphics_state: Dictionary
) -> float:
	if _sun_light == null:
		return time_of_day
	var next_time = _atmosphere_cycle.advance_time(time_of_day, delta, day_night_cycle_enabled, day_length_seconds)
	var atmosphere_state: Dictionary = _atmosphere_cycle.apply_to_light_and_environment(
		next_time,
		_sun_light,
		_world_environment,
		0.08,
		1.32,
		0.06,
		1.08,
		0.03,
		0.95,
		0.06,
		1.0
	)
	_apply_atmospheric_fog(float(atmosphere_state.get("daylight", 0.0)), graphics_state)
	return next_time

func apply_graphics_state(
	graphics_state: Dictionary,
	simulation_ticks_per_second: float,
	living_profile_push_interval_ticks: int
) -> Dictionary:
	var merged_state = SimulationGraphicsSettingsScript.merge_with_defaults(graphics_state)
	var performance_result = _apply_performance_toggles(
		merged_state,
		simulation_ticks_per_second,
		living_profile_push_interval_ticks
	)
	if _sun_light != null:
		_sun_light.shadow_enabled = bool(merged_state.get("shadows_enabled", false))
	if _world_environment != null and _world_environment.environment != null:
		var env: Environment = _world_environment.environment
		_set_env_flag_if_supported(env, "ssr_enabled", bool(merged_state.get("ssr_enabled", false)))
		_set_env_flag_if_supported(env, "ssao_enabled", bool(merged_state.get("ssao_enabled", false)))
		_set_env_flag_if_supported(env, "ssil_enabled", bool(merged_state.get("ssil_enabled", false)))
		_set_env_flag_if_supported(env, "sdfgi_enabled", bool(merged_state.get("sdfgi_enabled", false)))
		_set_env_flag_if_supported(env, "glow_enabled", bool(merged_state.get("glow_enabled", false)))
		_set_env_flag_if_supported(env, "fog_enabled", bool(merged_state.get("fog_enabled", false)))
		_set_env_flag_if_supported(env, "volumetric_fog_enabled", bool(merged_state.get("volumetric_fog_enabled", false)))
	if _environment_controller != null:
		if _environment_controller.has_method("set_terrain_chunk_size"):
			_environment_controller.call("set_terrain_chunk_size", int(merged_state.get("terrain_chunk_size_blocks", 12)))
		if _environment_controller.has_method("set_water_render_mode"):
			_environment_controller.call("set_water_render_mode", "shader" if bool(merged_state.get("water_shader_enabled", false)) else "simple")
		if _environment_controller.has_method("set_ocean_surface_enabled"):
			_environment_controller.call("set_ocean_surface_enabled", bool(merged_state.get("ocean_surface_enabled", false)))
		if _environment_controller.has_method("set_river_overlays_enabled"):
			_environment_controller.call("set_river_overlays_enabled", bool(merged_state.get("river_overlays_enabled", false)))
		if _environment_controller.has_method("set_rain_post_fx_enabled"):
			_environment_controller.call("set_rain_post_fx_enabled", bool(merged_state.get("rain_post_fx_enabled", false)))
		if _environment_controller.has_method("set_clouds_enabled"):
			_environment_controller.call("set_clouds_enabled", bool(merged_state.get("clouds_enabled", false)))
		if _environment_controller.has_method("set_cloud_quality_settings"):
			_environment_controller.call("set_cloud_quality_settings", String(merged_state.get("cloud_quality", "low")), float(merged_state.get("cloud_density_scale", 0.25)))
		if _environment_controller.has_method("set_cloud_density_scale"):
			_environment_controller.call("set_cloud_density_scale", float(merged_state.get("cloud_density_scale", 0.25)))
		if _environment_controller.has_method("set_rain_visual_intensity_scale"):
			_environment_controller.call("set_rain_visual_intensity_scale", float(merged_state.get("rain_visual_intensity_scale", 0.25)))
		if _environment_controller.has_method("get_graphics_state"):
			var env_state = _environment_controller.call("get_graphics_state")
			if env_state is Dictionary:
				for key_variant in (env_state as Dictionary).keys():
					merged_state[String(key_variant)] = (env_state as Dictionary).get(key_variant)
	merged_state = SimulationGraphicsSettingsScript.merge_with_defaults(merged_state)
	merged_state["_visual_environment_update_interval_ticks"] = performance_result.get("visual_environment_update_interval_ticks", 4)
	return merged_state

func sanitize_graphics_value(option_id: String, value):
	return SimulationGraphicsSettingsScript.sanitize_value(option_id, value)

func _apply_performance_toggles(
	graphics_state: Dictionary,
	simulation_ticks_per_second: float,
	living_profile_push_interval_ticks: int
) -> Dictionary:
	var simulation_rate_override_enabled = bool(graphics_state.get("simulation_rate_override_enabled", false))
	var simulation_ticks_per_second_override = clampf(float(graphics_state.get("simulation_ticks_per_second_override", 2.0)), 0.5, 30.0)
	var simulation_locality_enabled = bool(graphics_state.get("simulation_locality_enabled", true))
	var simulation_locality_dynamic_enabled = bool(graphics_state.get("simulation_locality_dynamic_enabled", true))
	var simulation_locality_radius_tiles = maxi(0, int(graphics_state.get("simulation_locality_radius_tiles", 1)))
	var weather_solver_decimation_enabled = bool(graphics_state.get("weather_solver_decimation_enabled", false))
	var hydrology_solver_decimation_enabled = bool(graphics_state.get("hydrology_solver_decimation_enabled", false))
	var erosion_solver_decimation_enabled = bool(graphics_state.get("erosion_solver_decimation_enabled", false))
	var solar_solver_decimation_enabled = bool(graphics_state.get("solar_solver_decimation_enabled", false))
	var weather_gpu_compute_enabled = bool(graphics_state.get("weather_gpu_compute_enabled", true))
	var hydrology_gpu_compute_enabled = bool(graphics_state.get("hydrology_gpu_compute_enabled", true))
	var erosion_gpu_compute_enabled = bool(graphics_state.get("erosion_gpu_compute_enabled", true))
	var solar_gpu_compute_enabled = bool(graphics_state.get("solar_gpu_compute_enabled", true))
	var climate_fast_interval_ticks = maxi(1, int(graphics_state.get("climate_fast_interval_ticks", 4)))
	var climate_slow_interval_ticks = maxi(1, int(graphics_state.get("climate_slow_interval_ticks", 8)))
	var resource_pipeline_decimation_enabled = bool(graphics_state.get("resource_pipeline_decimation_enabled", false))
	var structure_lifecycle_decimation_enabled = bool(graphics_state.get("structure_lifecycle_decimation_enabled", false))
	var culture_cycle_decimation_enabled = bool(graphics_state.get("culture_cycle_decimation_enabled", false))
	var society_fast_interval_ticks = maxi(1, int(graphics_state.get("society_fast_interval_ticks", 4)))
	var society_slow_interval_ticks = maxi(1, int(graphics_state.get("society_slow_interval_ticks", 8)))
	var weather_texture_upload_decimation_enabled = bool(graphics_state.get("weather_texture_upload_decimation_enabled", false))
	var surface_texture_upload_decimation_enabled = bool(graphics_state.get("surface_texture_upload_decimation_enabled", false))
	var solar_texture_upload_decimation_enabled = bool(graphics_state.get("solar_texture_upload_decimation_enabled", false))
	var texture_upload_interval_ticks = maxi(1, int(graphics_state.get("texture_upload_interval_ticks", 8)))
	var texture_upload_budget_texels = maxi(512, int(graphics_state.get("texture_upload_budget_texels", 4096)))
	var ecology_step_decimation_enabled = bool(graphics_state.get("ecology_step_decimation_enabled", false))
	var ecology_step_interval_seconds = clampf(float(graphics_state.get("ecology_step_interval_seconds", 0.2)), 0.05, 0.5)
	var ecology_voxel_size_meters = clampf(float(graphics_state.get("ecology_voxel_size_meters", 1.0)), 0.5, 3.0)
	var ecology_vertical_extent_meters = clampf(float(graphics_state.get("ecology_vertical_extent_meters", 3.0)), 1.0, 8.0)
	var smell_gpu_compute_enabled = bool(graphics_state.get("smell_gpu_compute_enabled", false))
	var wind_gpu_compute_enabled = bool(graphics_state.get("wind_gpu_compute_enabled", false))
	var voxel_process_gating_enabled = bool(graphics_state.get("voxel_process_gating_enabled", true))
	var voxel_dynamic_tick_rate_enabled = bool(graphics_state.get("voxel_dynamic_tick_rate_enabled", true))
	var voxel_tick_min_interval_seconds = clampf(float(graphics_state.get("voxel_tick_min_interval_seconds", 0.05)), 0.01, 1.2)
	var voxel_tick_max_interval_seconds = clampf(float(graphics_state.get("voxel_tick_max_interval_seconds", 0.6)), voxel_tick_min_interval_seconds, 3.0)
	var voxel_smell_step_radius_cells = maxi(1, int(graphics_state.get("voxel_smell_step_radius_cells", 1)))
	var smell_query_acceleration_enabled = bool(graphics_state.get("smell_query_acceleration_enabled", true))
	var smell_query_top_k_per_layer = maxi(8, int(graphics_state.get("smell_query_top_k_per_layer", 48)))
	var smell_query_update_interval_seconds = clampf(float(graphics_state.get("smell_query_update_interval_seconds", 0.25)), 0.01, 2.0)
	var voxel_gate_smell_enabled = bool(graphics_state.get("voxel_gate_smell_enabled", true))
	var voxel_gate_plants_enabled = bool(graphics_state.get("voxel_gate_plants_enabled", true))
	var voxel_gate_mammals_enabled = bool(graphics_state.get("voxel_gate_mammals_enabled", true))
	var voxel_gate_shelter_enabled = bool(graphics_state.get("voxel_gate_shelter_enabled", true))
	var voxel_gate_profile_refresh_enabled = bool(graphics_state.get("voxel_gate_profile_refresh_enabled", true))
	var voxel_gate_edible_index_enabled = bool(graphics_state.get("voxel_gate_edible_index_enabled", true))

	var target_sim_ticks_per_second = simulation_ticks_per_second_override if simulation_rate_override_enabled else simulation_ticks_per_second
	var target_profile_push_interval = 8 if simulation_rate_override_enabled else living_profile_push_interval_ticks
	var visual_environment_update_interval_ticks = 8 if simulation_rate_override_enabled else 4
	_loop_controller.set_timing(target_sim_ticks_per_second, target_profile_push_interval)

	if _simulation_controller != null:
		if _simulation_controller.has_method("set_locality_processing_config"):
			_simulation_controller.call(
				"set_locality_processing_config",
				simulation_locality_enabled,
				simulation_locality_dynamic_enabled,
				simulation_locality_radius_tiles
			)
		else:
			_simulation_controller.set("locality_processing_enabled", simulation_locality_enabled)
			_simulation_controller.set("locality_dynamic_tick_rate_enabled", simulation_locality_dynamic_enabled)
			_simulation_controller.set("locality_activity_radius_tiles", simulation_locality_radius_tiles)
		if _simulation_controller.has_method("set_gpu_compute_modes"):
			_simulation_controller.call(
				"set_gpu_compute_modes",
				weather_gpu_compute_enabled,
				hydrology_gpu_compute_enabled,
				erosion_gpu_compute_enabled,
				solar_gpu_compute_enabled
			)
		else:
			_simulation_controller.set("weather_gpu_compute_enabled", weather_gpu_compute_enabled)
			_simulation_controller.set("hydrology_gpu_compute_enabled", hydrology_gpu_compute_enabled)
			_simulation_controller.set("erosion_gpu_compute_enabled", erosion_gpu_compute_enabled)
			_simulation_controller.set("solar_gpu_compute_enabled", solar_gpu_compute_enabled)
		_simulation_controller.set("weather_step_interval_ticks", climate_fast_interval_ticks if weather_solver_decimation_enabled else 2)
		_simulation_controller.set("hydrology_step_interval_ticks", climate_fast_interval_ticks if hydrology_solver_decimation_enabled else 2)
		_simulation_controller.set("erosion_step_interval_ticks", climate_slow_interval_ticks if erosion_solver_decimation_enabled else 4)
		_simulation_controller.set("solar_step_interval_ticks", climate_slow_interval_ticks if solar_solver_decimation_enabled else 4)
		_simulation_controller.set("resource_pipeline_interval_ticks", society_fast_interval_ticks if resource_pipeline_decimation_enabled else 2)
		_simulation_controller.set("structure_lifecycle_interval_ticks", society_fast_interval_ticks if structure_lifecycle_decimation_enabled else 2)
		_simulation_controller.set("culture_cycle_interval_ticks", society_slow_interval_ticks if culture_cycle_decimation_enabled else 4)

	if _environment_controller != null:
		_environment_controller.set("weather_texture_update_interval_ticks", texture_upload_interval_ticks if weather_texture_upload_decimation_enabled else 4)
		_environment_controller.set("surface_texture_update_interval_ticks", texture_upload_interval_ticks if surface_texture_upload_decimation_enabled else 4)
		_environment_controller.set("solar_texture_update_interval_ticks", texture_upload_interval_ticks if solar_texture_upload_decimation_enabled else 4)
		var any_texture_throttle = weather_texture_upload_decimation_enabled or surface_texture_upload_decimation_enabled or solar_texture_upload_decimation_enabled
		_environment_controller.set("field_texture_update_budget_cells", texture_upload_budget_texels if any_texture_throttle else 8192)

	if _ecology_controller != null:
		if _ecology_controller.has_method("set_smell_gpu_compute_enabled"):
			_ecology_controller.call("set_smell_gpu_compute_enabled", smell_gpu_compute_enabled)
		else:
			_ecology_controller.set("smell_gpu_compute_enabled", smell_gpu_compute_enabled)
		if _ecology_controller.has_method("set_wind_gpu_compute_enabled"):
			_ecology_controller.call("set_wind_gpu_compute_enabled", wind_gpu_compute_enabled)
		else:
			_ecology_controller.set("wind_gpu_compute_enabled", wind_gpu_compute_enabled)
		_ecology_controller.set("plant_step_interval_seconds", ecology_step_interval_seconds if ecology_step_decimation_enabled else 0.1)
		_ecology_controller.set("mammal_step_interval_seconds", ecology_step_interval_seconds if ecology_step_decimation_enabled else 0.1)
		_ecology_controller.set("living_profile_refresh_interval_seconds", (ecology_step_interval_seconds * 2.0) if ecology_step_decimation_enabled else 0.2)
		_ecology_controller.set("edible_index_rebuild_interval_seconds", (ecology_step_interval_seconds * 3.5) if ecology_step_decimation_enabled else 0.35)
		_ecology_controller.set("max_smell_substeps_per_physics_frame", 2 if ecology_step_decimation_enabled else 3)
		_ecology_controller.set("voxel_process_gating_enabled", voxel_process_gating_enabled)
		_ecology_controller.set("voxel_dynamic_tick_rate_enabled", voxel_dynamic_tick_rate_enabled)
		_ecology_controller.set("voxel_tick_min_interval_seconds", voxel_tick_min_interval_seconds)
		_ecology_controller.set("voxel_tick_max_interval_seconds", voxel_tick_max_interval_seconds)
		_ecology_controller.set("voxel_smell_step_radius_cells", voxel_smell_step_radius_cells)
		_ecology_controller.set_meta("smell_query_acceleration_enabled", smell_query_acceleration_enabled)
		_ecology_controller.set_meta("smell_query_top_k_per_layer", smell_query_top_k_per_layer)
		_ecology_controller.set_meta("smell_query_update_interval_seconds", smell_query_update_interval_seconds)
		_ecology_controller.set("voxel_gate_smell_enabled", voxel_gate_smell_enabled)
		_ecology_controller.set("voxel_gate_plants_enabled", voxel_gate_plants_enabled)
		_ecology_controller.set("voxel_gate_mammals_enabled", voxel_gate_mammals_enabled)
		_ecology_controller.set("voxel_gate_shelter_enabled", voxel_gate_shelter_enabled)
		_ecology_controller.set("voxel_gate_profile_refresh_enabled", voxel_gate_profile_refresh_enabled)
		_ecology_controller.set("voxel_gate_edible_index_enabled", voxel_gate_edible_index_enabled)
		_apply_smell_query_acceleration_config(
			smell_query_acceleration_enabled,
			smell_query_top_k_per_layer,
			smell_query_update_interval_seconds
		)
		if _ecology_controller.has_method("set_smell_voxel_size"):
			_ecology_controller.call("set_smell_voxel_size", ecology_voxel_size_meters)
		if _ecology_controller.has_method("set_smell_vertical_half_extent"):
			_ecology_controller.call("set_smell_vertical_half_extent", ecology_vertical_extent_meters)

	return {"visual_environment_update_interval_ticks": visual_environment_update_interval_ticks}

func _apply_smell_query_acceleration_config(enabled: bool, top_k_per_layer: int, update_interval_seconds: float) -> void:
	if _ecology_controller == null:
		return
	var smell_field = _ecology_controller.get("_smell_field")
	if smell_field == null:
		return
	if smell_field.has_method("set_query_acceleration"):
		smell_field.call("set_query_acceleration", enabled, top_k_per_layer, update_interval_seconds)

func _set_env_flag_if_supported(env: Environment, property_name: String, enabled: bool) -> void:
	if env == null:
		return
	if _supported_environment_flags.is_empty():
		cache_environment_supported_flags()
	if not bool(_supported_environment_flags.get(property_name, false)):
		return
	env.set(property_name, enabled)

func _apply_atmospheric_fog(_daylight: float, graphics_state: Dictionary) -> void:
	if _world_environment == null or _world_environment.environment == null:
		return
	var env: Environment = _world_environment.environment
	var fog_enabled = bool(graphics_state.get("fog_enabled", false))
	var volumetric_fog_enabled = bool(graphics_state.get("volumetric_fog_enabled", false))
	if fog_enabled != _last_fog_enabled:
		_set_env_flag_if_supported(env, "fog_enabled", fog_enabled)
		_last_fog_enabled = fog_enabled
	if volumetric_fog_enabled != _last_volumetric_fog_enabled:
		_set_env_flag_if_supported(env, "volumetric_fog_enabled", volumetric_fog_enabled)
		_last_volumetric_fog_enabled = volumetric_fog_enabled
