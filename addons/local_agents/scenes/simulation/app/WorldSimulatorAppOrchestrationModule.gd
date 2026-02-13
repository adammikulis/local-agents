extends "res://addons/local_agents/scenes/simulation/app/WorldSimulatorAppSimulationModule.gd"

func apply_scenario_resource(scenario: Resource) -> void:
	if scenario == null:
		return
	if not (scenario is SimulationScenarioResourceScript):
		return
	var typed = scenario as SimulationScenarioResourceScript
	startup_scenario = typed
	_seed_line_edit.text = typed.seed_text
	_width_spin.value = typed.world_width
	_depth_spin.value = typed.world_depth
	_world_height_spin.value = typed.world_height
	_sea_level_spin.value = typed.sea_level
	var selected_idx = 1
	match typed.backend_mode:
		"cpu":
			selected_idx = 0
		"gpu_hybrid":
			selected_idx = 1
		"gpu_aggressive":
			selected_idx = 2
		"ultra":
			selected_idx = 3
	_sim_backend_option.selected = clampi(selected_idx, 0, maxi(0, _sim_backend_option.item_count - 1))
	_apply_sim_backend_mode()
	if typed.auto_generate_on_ready:
		_generate_world()
	if typed.start_paused:
		_is_playing = false

func _push_state_from_runtime() -> void:
	_state.sim_tick = _sim_tick
	_state.simulated_seconds = _simulated_seconds
	_state.simulation_accumulator = _sim_accum
	_state.active_branch_id = _active_branch_id
	_state.landslide_count = _landslide_count
	_state.solar_seed = _solar_seed
	_state.world_snapshot.set_from_dictionary(_world_snapshot, _sim_tick)
	_state.hydrology_snapshot.set_from_dictionary(_hydrology_snapshot, _sim_tick)
	_state.weather_snapshot.set_from_dictionary(_weather_snapshot, _sim_tick)
	_state.geology_snapshot.set_from_dictionary(_world_snapshot.get("geology", {}), _sim_tick)
	_state.solar_snapshot.set_from_dictionary(_solar_snapshot, _sim_tick)
	_session_controller.state = _state

func _pull_runtime_from_state() -> void:
	_sim_tick = _state.sim_tick
	_simulated_seconds = _state.simulated_seconds
	_sim_accum = _state.simulation_accumulator
	_active_branch_id = _state.active_branch_id
	_landslide_count = _state.landslide_count
	_solar_seed = _state.solar_seed
	_world_snapshot = _state.world_snapshot.to_dictionary()
	_hydrology_snapshot = _state.hydrology_snapshot.to_dictionary()
	_weather_snapshot = _state.weather_snapshot.to_dictionary()
	_solar_snapshot = _state.solar_snapshot.to_dictionary()

func _ready() -> void:
	_rng.randomize()
	_time_of_day = clampf(start_time_of_day, 0.0, 1.0)
	_random_seed_button.pressed.connect(_on_random_seed_pressed)
	_generate_button.pressed.connect(_generate_world)
	_graphics_button.pressed.connect(_on_graphics_button_pressed)
	_apply_terrain_preset_button.pressed.connect(_on_apply_terrain_preset_pressed)
	_show_flow_checkbox.toggled.connect(func(_enabled: bool): _generate_world())
	_seed_line_edit.text_submitted.connect(func(_text: String): _generate_world())
	_water_flow_speed_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_noise_scale_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_foam_strength_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_wave_strength_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_flow_dir_x_spin.value_changed.connect(_on_water_shader_control_changed)
	_water_flow_dir_z_spin.value_changed.connect(_on_water_shader_control_changed)
	_eruption_interval_spin.value_changed.connect(func(v: float): eruption_interval_seconds = maxf(0.1, v))
	_island_growth_spin.value_changed.connect(func(v: float): island_growth_per_eruption = maxf(0.0, v))
	_new_vent_chance_spin.value_changed.connect(func(v: float): new_vent_spawn_chance = clampf(v, 0.0, 1.0))
	_moon_cycle_days_spin.value_changed.connect(func(v: float):
		lunar_cycle_days = maxf(1.0, v)
		_apply_tide_shader_controls(true)
	)
	_moon_tide_strength_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_moon_tide_range_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_gravity_strength_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_gravity_radius_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_ocean_amplitude_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_ocean_frequency_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_ocean_chop_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_water_lod_start_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_water_lod_end_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_water_lod_min_spin.value_changed.connect(func(_v: float): _apply_tide_shader_controls(true))
	_cloud_quality_option.item_selected.connect(func(_index: int): _apply_cloud_and_debug_quality())
	_cloud_density_spin.value_changed.connect(func(_v: float): _apply_cloud_and_debug_quality())
	_debug_density_spin.value_changed.connect(func(_v: float): _apply_cloud_and_debug_quality())
	_ocean_quality_option.item_selected.connect(func(_i: int): _apply_ocean_quality_preset())
	_sim_backend_option.item_selected.connect(func(_i: int): _apply_sim_backend_mode())
	if _sim_backend_option.item_count < 4:
		_sim_backend_option.add_item("Ultra Performance")
	_sim_tick_cap_spin.value_changed.connect(func(v: float): max_sim_ticks_per_frame = clampi(int(round(v)), 1, 24))
	_dynamic_target_fps_spin.value_changed.connect(func(v: float): dynamic_target_fps = clampf(v, 20.0, 120.0))
	_dynamic_check_spin.value_changed.connect(func(v: float): dynamic_quality_check_seconds = clampf(v, 0.2, 5.0))
	_terrain_chunk_spin.value_changed.connect(_on_terrain_chunk_size_changed)
	_sim_budget_ms_spin.value_changed.connect(func(v: float): sim_budget_ms_per_frame = clampf(v, 1.0, 25.0))
	_timelapse_stride_spin.value_changed.connect(func(v: float): timelapse_record_every_ticks = clampi(int(round(v)), 1, 64))
	_flow_refresh_spin.value_changed.connect(func(v: float): flow_overlay_refresh_seconds = clampf(v, 0.02, 2.0))
	_terrain_apply_spin.value_changed.connect(func(v: float): terrain_apply_interval_seconds = clampf(v, 0.0, 1.0))
	_enable_fog_checkbox.toggled.connect(func(_v: bool): _apply_environment_toggles())
	_enable_sdfgi_checkbox.toggled.connect(func(_v: bool): _apply_environment_toggles())
	_enable_glow_checkbox.toggled.connect(func(_v: bool): _apply_environment_toggles())
	_enable_clouds_checkbox.toggled.connect(func(_v: bool):
		_clouds_enabled = _v
		_apply_cloud_and_debug_quality()
	)
	_enable_shadows_checkbox.toggled.connect(func(_v: bool): _apply_environment_toggles())
	_lightning_button.pressed.connect(_on_lightning_strike_pressed)
	_start_year_spin.value_changed.connect(func(_v: float): _generate_world())
	_years_per_tick_spin.value_changed.connect(func(_v: float): _refresh_hud())
	if _simulation_hud != null:
		_simulation_hud.play_pressed.connect(_on_hud_play_pressed)
		_simulation_hud.pause_pressed.connect(_on_hud_pause_pressed)
		_simulation_hud.fast_forward_pressed.connect(_on_hud_fast_forward_pressed)
		_simulation_hud.rewind_pressed.connect(_on_hud_rewind_pressed)
		_simulation_hud.fork_pressed.connect(_on_hud_fork_pressed)
		if _simulation_hud.has_signal("overlays_changed"):
			_simulation_hud.overlays_changed.connect(_on_hud_overlays_changed)
	if _ecology_controller != null and _ecology_controller.has_method("set_debug_overlay"):
		_ecology_controller.call("set_debug_overlay", _debug_overlay_root)
	_sim_tick_cap_spin.value = max_sim_ticks_per_frame
	_dynamic_target_fps_spin.value = dynamic_target_fps
	_dynamic_check_spin.value = dynamic_quality_check_seconds
	_sim_budget_ms_spin.value = sim_budget_ms_per_frame
	_timelapse_stride_spin.value = timelapse_record_every_ticks
	_flow_refresh_spin.value = flow_overlay_refresh_seconds
	_terrain_apply_spin.value = terrain_apply_interval_seconds
	_apply_cloud_and_debug_quality()
	_apply_ocean_quality_preset()
	_apply_sim_backend_mode()
	_on_terrain_chunk_size_changed(_terrain_chunk_spin.value)
	_apply_environment_toggles()
	_apply_tide_shader_controls(true)
	_setup_debug_column_ui()
	_setup_manual_eruption_controls()
	_interaction_controller.configure_camera(_camera)
	_set_graphics_options_expanded(false)
	_on_hud_overlays_changed(true, true, true, true, true, true)
	if startup_scenario != null:
		apply_scenario_resource(startup_scenario)
	elif _seed_line_edit.text.strip_edges() == "":
		_on_random_seed_pressed()
	else:
		_generate_world()


func _process(delta: float) -> void:
	_interaction_controller.process_camera(delta)
	_update_day_night(delta)
	_tide_uniform_accum += maxf(0.0, delta)
	_apply_tide_shader_controls(false)
	_update_lava_fx(delta)
	_apply_dynamic_quality(delta)
	if _is_playing:
		_step_environment_simulation(delta * float(_ticks_per_frame))
	_refresh_hud()


func _on_random_seed_pressed() -> void:
	_seed_line_edit.text = "demo_%d" % _rng.randi_range(10000, 99999)
	_generate_world()

func _generate_world() -> void:
	_stop_async_workers()
	var config = _current_worldgen_config_for_tick(0)

	var seed_text = _seed_line_edit.text.strip_edges()
	if seed_text == "":
		seed_text = "demo_seed"
		_seed_line_edit.text = seed_text
	var seed = int(hash(seed_text))
	var generated = _environment_systems_controller.generate(seed, config)
	var world = generated.get("world", {})
	var hydrology = generated.get("hydrology", {})
	_world_snapshot = world.duplicate(true)
	_hydrology_snapshot = hydrology.duplicate(true)
	_sim_tick = 0
	_simulated_seconds = 0.0
	_sim_accum = 0.0
	_landslide_count = 0
	_active_branch_id = "main"
	_is_playing = true
	_ticks_per_frame = 1
	_timelapse_snapshots.clear()
	_pending_hydro_changed_tiles.clear()
	_pending_hydro_rebake_events = 0
	_pending_hydro_rebake_seconds = 0.0
	_geology_controller.reset()
	_weather_tick_accum = 0.0
	_erosion_tick_accum = 0.0
	_solar_tick_accum = 0.0
	_flow_overlay_accum = flow_overlay_refresh_seconds
	_terrain_apply_accum = terrain_apply_interval_seconds
	_pending_terrain_changed_tiles.clear()
	_local_activity_by_tile.clear()
	_manual_vent_place_mode = false
	_manual_eruption_active = false
	_manual_selected_vent_tile_id = ""
	_selected_feature.clear()
	_flow_overlay_dirty = true
	_weather_bench_cpu_ms = -1.0
	_weather_bench_gpu_ms = -1.0
	_solar_bench_cpu_ms = -1.0
	_solar_bench_gpu_ms = -1.0
	_dynamic_pressure_low = 0
	_dynamic_pressure_high = 0
	_sim_budget_debt_ms = 0.0
	_sim_budget_credit_ms = 0.0
	_clear_lava_fx()
	var weather_seed = int(hash("%s_weather" % seed_text))
	var erosion_seed = int(hash("%s_erosion" % seed_text))
	var solar_seed = int(hash("%s_solar" % seed_text))
	var volcanic_seed = int(hash("%s_volcanic" % seed_text))
	_solar_seed = solar_seed
	_geology_controller.set_seed(volcanic_seed)
	_apply_sim_backend_mode()
	_weather.configure_environment(_world_snapshot, _hydrology_snapshot, weather_seed)
	_weather_snapshot = _weather.current_snapshot(0)
	_erosion.configure_environment(_world_snapshot, _hydrology_snapshot, erosion_seed)
	_erosion_snapshot = _erosion.current_snapshot(0)
	_solar.configure_environment(_world_snapshot, solar_seed)
	_solar_snapshot = _solar.current_snapshot(0)
	_solar_snapshot["seed"] = solar_seed
	_refresh_manual_vent_status()

	_terrain_renderer.apply_generation(_environment_controller, _world_snapshot, _hydrology_snapshot, int(round(_terrain_chunk_spin.value)))
	_water_renderer.apply_state(_environment_controller, _weather_snapshot, _solar_snapshot)
	_sync_living_world_features(true)
	_apply_water_shader_controls()
	_render_flow_overlay(_world_snapshot, config)
	_frame_camera(_world_snapshot)
	_update_stats(_world_snapshot, _hydrology_snapshot, seed)
	_record_timelapse_snapshot(_sim_tick)
	_push_state_from_runtime()
	call_deferred("_run_gpu_benchmarks")


func _apply_sim_backend_mode() -> void:
	match _sim_backend_option.selected:
		0:
			_sim_backend_mode = "cpu"
		1:
			_sim_backend_mode = "gpu_hybrid"
		2:
			_sim_backend_mode = "gpu_aggressive"
		_:
			_sim_backend_mode = "ultra"
	var compact = _sim_backend_mode != "cpu"
	_ultra_perf_mode = _sim_backend_mode == "ultra"
	if _weather != null and _weather.has_method("set_emit_rows"):
		_weather.call("set_emit_rows", not compact)
	if _weather != null and _weather.has_method("set_compute_enabled"):
		_weather.call("set_compute_enabled", _sim_backend_mode == "gpu_aggressive" or _sim_backend_mode == "ultra")
	if _erosion != null and _erosion.has_method("set_emit_rows"):
		_erosion.call("set_emit_rows", not compact)
	if _erosion != null and _erosion.has_method("set_compute_enabled"):
		_erosion.call("set_compute_enabled", _sim_backend_mode == "gpu_aggressive" or _sim_backend_mode == "ultra")
	if _solar != null and _solar.has_method("set_emit_rows"):
		_solar.call("set_emit_rows", not compact)
	if _solar != null and _solar.has_method("set_compute_enabled"):
		_solar.call("set_compute_enabled", _sim_backend_mode == "gpu_aggressive" or _sim_backend_mode == "ultra")
	if _solar != null and _solar.has_method("set_sync_stride"):
		var sync_stride = 1
		if _sim_backend_mode == "gpu_hybrid":
			sync_stride = 2
		elif _sim_backend_mode == "gpu_aggressive":
			sync_stride = 4
		elif _sim_backend_mode == "ultra":
			sync_stride = 8
		_solar.call("set_sync_stride", sync_stride)
	if _sim_backend_mode == "ultra":
		max_sim_ticks_per_frame = mini(max_sim_ticks_per_frame, 2)
		timelapse_record_every_ticks = maxi(8, timelapse_record_every_ticks)
		flow_overlay_refresh_seconds = maxf(flow_overlay_refresh_seconds, 0.5)
		terrain_apply_interval_seconds = maxf(terrain_apply_interval_seconds, 0.18)
		sim_budget_ms_per_frame = minf(sim_budget_ms_per_frame, 3.0)
	elif _sim_backend_mode == "gpu_aggressive":
		max_sim_ticks_per_frame = mini(max_sim_ticks_per_frame, 3)
		timelapse_record_every_ticks = maxi(4, timelapse_record_every_ticks)
		flow_overlay_refresh_seconds = maxf(flow_overlay_refresh_seconds, 0.35)
		terrain_apply_interval_seconds = maxf(terrain_apply_interval_seconds, 0.12)
		sim_budget_ms_per_frame = minf(sim_budget_ms_per_frame, 5.0)
	elif compact:
		max_sim_ticks_per_frame = mini(max_sim_ticks_per_frame, 4)
	else:
		max_sim_ticks_per_frame = maxi(max_sim_ticks_per_frame, 6)
	_sim_tick_cap_spin.value = max_sim_ticks_per_frame
	_timelapse_stride_spin.value = timelapse_record_every_ticks
	_flow_refresh_spin.value = flow_overlay_refresh_seconds
	_terrain_apply_spin.value = terrain_apply_interval_seconds
	_sim_budget_ms_spin.value = sim_budget_ms_per_frame

func _apply_dynamic_quality(delta: float) -> void:
	if _auto_scale_checkbox == null or not _auto_scale_checkbox.button_pressed:
		return
	_dynamic_quality_accum += maxf(0.0, delta)
	if _dynamic_quality_accum < dynamic_quality_check_seconds:
		return
	_dynamic_quality_accum = 0.0
	var fps = Engine.get_frames_per_second()
	if fps <= 0:
		return
	var mode_perf = (_perf_ewma_by_mode.get(_sim_backend_mode, {}) as Dictionary)
	var tick_ms = float(mode_perf.get("tick_total_ms", 0.0))
	var target_frame_ms = 1000.0 / maxf(1.0, dynamic_target_fps)
	var target_sim_ms = minf(sim_budget_ms_per_frame, target_frame_ms * 0.5)
	if tick_ms > 0.0:
		if tick_ms > target_sim_ms * 1.08:
			_sim_budget_debt_ms += tick_ms - target_sim_ms
			_sim_budget_credit_ms = maxf(0.0, _sim_budget_credit_ms - 0.5)
		elif tick_ms < target_sim_ms * 0.82:
			_sim_budget_credit_ms += target_sim_ms - tick_ms
			_sim_budget_debt_ms = maxf(0.0, _sim_budget_debt_ms - 0.5)
	var low_pressure = float(fps) < dynamic_target_fps - 6.0 or _sim_budget_debt_ms > target_sim_ms * 2.0
	var high_pressure = float(fps) > dynamic_target_fps + 8.0 and _sim_budget_credit_ms > target_sim_ms * 2.0
	_dynamic_pressure_low = _dynamic_pressure_low + 1 if low_pressure else maxi(0, _dynamic_pressure_low - 1)
	_dynamic_pressure_high = _dynamic_pressure_high + 1 if high_pressure else maxi(0, _dynamic_pressure_high - 1)
	if _dynamic_pressure_low >= 2:
		_dynamic_pressure_low = 0
		if _ocean_quality_option.selected > 0:
			_ocean_quality_option.selected -= 1
			_apply_ocean_quality_preset()
		elif _cloud_quality_option.selected > 0:
			_cloud_quality_option.selected -= 1
			_apply_cloud_and_debug_quality()
		elif _enable_sdfgi_checkbox.button_pressed:
			_enable_sdfgi_checkbox.button_pressed = false
			_apply_environment_toggles()
		elif _enable_glow_checkbox.button_pressed:
			_enable_glow_checkbox.button_pressed = false
			_apply_environment_toggles()
		elif _enable_shadows_checkbox.button_pressed:
			_enable_shadows_checkbox.button_pressed = false
			_apply_environment_toggles()
		max_sim_ticks_per_frame = maxi(1, max_sim_ticks_per_frame - 1)
		sim_budget_ms_per_frame = clampf(sim_budget_ms_per_frame - 0.5, 1.0, 25.0)
		_sim_budget_ms_spin.value = sim_budget_ms_per_frame
		_sim_tick_cap_spin.value = max_sim_ticks_per_frame
		_sim_budget_debt_ms = maxf(0.0, _sim_budget_debt_ms - target_sim_ms * 0.5)
	elif _dynamic_pressure_high >= 3:
		_dynamic_pressure_high = 0
		if _cloud_quality_option.selected < _cloud_quality_option.item_count - 1:
			_cloud_quality_option.selected += 1
			_apply_cloud_and_debug_quality()
		elif _ocean_quality_option.selected < _ocean_quality_option.item_count - 1:
			_ocean_quality_option.selected += 1
			_apply_ocean_quality_preset()
		elif not _enable_shadows_checkbox.button_pressed:
			_enable_shadows_checkbox.button_pressed = true
			_apply_environment_toggles()
		elif not _enable_glow_checkbox.button_pressed:
			_enable_glow_checkbox.button_pressed = true
			_apply_environment_toggles()
		elif not _enable_sdfgi_checkbox.button_pressed:
			_enable_sdfgi_checkbox.button_pressed = true
			_apply_environment_toggles()
		max_sim_ticks_per_frame = mini(12, max_sim_ticks_per_frame + 1)
		sim_budget_ms_per_frame = clampf(sim_budget_ms_per_frame + 0.5, 1.0, 25.0)
		_sim_budget_ms_spin.value = sim_budget_ms_per_frame
		_sim_tick_cap_spin.value = max_sim_ticks_per_frame
		_sim_budget_credit_ms = maxf(0.0, _sim_budget_credit_ms - target_sim_ms * 0.5)


func _current_worldgen_config_for_tick(tick: int) -> Resource:
	var config = WorldGenConfigResourceScript.new()
	config.map_width = int(_width_spin.value)
	config.map_height = int(_depth_spin.value)
	config.voxel_world_height = int(_world_height_spin.value)
	config.voxel_sea_level = int(_sea_level_spin.value)
	config.voxel_surface_height_base = int(_surface_base_spin.value)
	config.voxel_surface_height_range = int(_surface_range_spin.value)
	config.voxel_noise_frequency = float(_noise_frequency_spin.value)
	config.voxel_noise_octaves = int(_noise_octaves_spin.value)
	config.voxel_noise_lacunarity = float(_noise_lacunarity_spin.value)
	config.voxel_noise_gain = float(_noise_gain_spin.value)
	config.voxel_surface_smoothing = float(_surface_smoothing_spin.value)
	config.cave_noise_threshold = float(_cave_threshold_spin.value)
	config.voxel_surface_height_base = clampi(config.voxel_surface_height_base, 2, maxi(3, config.voxel_world_height - 2))
	_apply_year_progression(config, tick)
	return config

func _year_at_tick(tick: int) -> float:
	return float(_start_year_spin.value) + float(tick) * float(_years_per_tick_spin.value)

func _apply_year_progression(config: Resource, tick: int) -> void:
	if config == null:
		return
	var year = _year_at_tick(tick)
	if _world_progression_profile != null and _world_progression_profile.has_method("apply_to_worldgen_config"):
		_world_progression_profile.call("apply_to_worldgen_config", config, year)
		return
	config.simulated_year = year
	config.progression_profile_id = "year_%d" % int(round(year))
	config.progression_temperature_shift = 0.0
	config.progression_moisture_shift = 0.0
	config.progression_food_density_multiplier = 1.0
	config.progression_wood_density_multiplier = 1.0
	config.progression_stone_density_multiplier = 1.0

func _current_worldgen_config() -> Resource:
	return _current_worldgen_config_for_tick(_sim_tick)

func _legacy_stats_placeholder() -> void:
	# Removed by refactor; kept as no-op to avoid accidental merge conflicts.
	pass


func _refresh_hud() -> void:
	if _simulation_hud == null:
		return
	var mode = "playing" if _is_playing else "paused"
	var year = _year_at_tick(_sim_tick)
	_simulation_hud.set_status_text(_hud_controller.build_status_text(year, _format_duration_hms(_simulated_seconds), _sim_tick, _active_branch_id, mode, _ticks_per_frame))
	var lunar = _current_lunar_debug()
	var details = _hud_controller.build_details_text(
		_weather_snapshot,
		_solar_snapshot,
		_landslide_count,
		float(lunar.get("phase_percent", 0.0)),
		String(lunar.get("state", "Neap")),
		float(lunar.get("multiplier", 1.0)),
		_sim_backend_mode,
		_ocean_quality_option.get_item_text(_ocean_quality_option.selected)
	)
	if _simulation_hud.has_method("set_details_text"):
		_simulation_hud.set_details_text(details)
	_update_perf_compare_label()

func _update_perf_compare_label() -> void:
	if _perf_compare_label == null:
		return
	var modes = ["cpu", "gpu_hybrid", "gpu_aggressive", "ultra"]
	var lines: Array[String] = []
	if _debug_compact_mode:
		var row = (_perf_ewma_by_mode.get(_sim_backend_mode, {}) as Dictionary)
		lines.append("%s tick %.2fms | w %.2f e %.2f s %.2f v %.2f t %.2f" % [
			_sim_backend_mode,
			float(row.get("tick_total_ms", 0.0)),
			float(row.get("weather_ms", 0.0)),
			float(row.get("erosion_ms", 0.0)),
			float(row.get("solar_ms", 0.0)),
			float(row.get("volcanic_ms", 0.0)),
			float(row.get("terrain_apply_ms", 0.0)),
		])
	else:
		for mode in modes:
			var row_full = (_perf_ewma_by_mode.get(mode, {}) as Dictionary)
			var marker = "*" if mode == _sim_backend_mode else " "
			lines.append("%s %s: tick %.2fms | w %.2f e %.2f s %.2f v %.2f t %.2f" % [
				marker,
				mode,
				float(row_full.get("tick_total_ms", 0.0)),
				float(row_full.get("weather_ms", 0.0)),
				float(row_full.get("erosion_ms", 0.0)),
				float(row_full.get("solar_ms", 0.0)),
				float(row_full.get("volcanic_ms", 0.0)),
				float(row_full.get("terrain_apply_ms", 0.0)),
			])
	var weather_bench_text = "weather bench cpu %.2fms gpu %.2fms" % [_weather_bench_cpu_ms, _weather_bench_gpu_ms] if _weather_bench_cpu_ms >= 0.0 else "weather bench pending"
	var solar_bench_text = "solar bench cpu %.2fms gpu %.2fms" % [_solar_bench_cpu_ms, _solar_bench_gpu_ms] if _solar_bench_cpu_ms >= 0.0 else "solar bench pending"
	var budget_text = "budget %.1fms debt %.2f credit %.2f" % [sim_budget_ms_per_frame, _sim_budget_debt_ms, _sim_budget_credit_ms]
	if _debug_compact_mode:
		lines.append("bench w %.2f/%.2f s %.2f/%.2f" % [_weather_bench_cpu_ms, _weather_bench_gpu_ms, _solar_bench_cpu_ms, _solar_bench_gpu_ms])
	else:
		lines.append(weather_bench_text)
		lines.append(solar_bench_text)
	lines.append(budget_text)
	_perf_compare_label.text = "\n".join(lines)

func _run_gpu_benchmarks() -> void:
	_run_weather_compute_benchmark()
	_run_solar_compute_benchmark()

func _run_weather_compute_benchmark() -> void:
	if _weather == null or not _weather.has_method("benchmark_cpu_vs_compute"):
		return
	var result = _weather.call("benchmark_cpu_vs_compute", 12, 0.5)
	if not (result is Dictionary):
		return
	var row = result as Dictionary
	if not bool(row.get("ok", false)):
		return
	_weather_bench_cpu_ms = float(row.get("cpu_ms_per_step", -1.0))
	_weather_bench_gpu_ms = float(row.get("gpu_ms_per_step", -1.0))

func _run_solar_compute_benchmark() -> void:
	if _solar == null or not _solar.has_method("benchmark_cpu_vs_compute"):
		return
	var result = _solar.call("benchmark_cpu_vs_compute", _world_snapshot, _weather_snapshot, 12, 0.5)
	if not (result is Dictionary):
		return
	var row = result as Dictionary
	if not bool(row.get("ok", false)):
		return
	_solar_bench_cpu_ms = float(row.get("cpu_ms_per_step", -1.0))
	_solar_bench_gpu_ms = float(row.get("gpu_ms_per_step", -1.0))

func _current_lunar_debug() -> Dictionary:
	var cycle_days = maxf(1.0, float(_moon_cycle_days_spin.value)) if _moon_cycle_days_spin != null else lunar_cycle_days
	var lunar_period_seconds = maxf(1.0, cycle_days * maxf(10.0, day_length_seconds))
	var moon_phase = fposmod(_simulated_seconds, lunar_period_seconds) / lunar_period_seconds
	var spring_neap = absf(cos(moon_phase * TAU))
	return {
		"phase_percent": moon_phase * 100.0,
		"state": "Spring" if spring_neap > 0.72 else "Neap",
		"multiplier": lerpf(0.25, 1.0, spring_neap),
	}

func _perf_record(metric: String, ms: float) -> void:
	var mode = _sim_backend_mode
	if not _perf_ewma_by_mode.has(mode):
		_perf_ewma_by_mode[mode] = {}
	var row = _perf_ewma_by_mode[mode] as Dictionary
	var prev = float(row.get(metric, ms))
	var alpha = 0.14
	row[metric] = lerpf(prev, ms, alpha)
	_perf_ewma_by_mode[mode] = row

func _exit_tree() -> void:
	_stop_async_workers()


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

func _format_duration_hms(total_seconds: float) -> String:
	var whole = maxi(0, int(floor(total_seconds)))
	var hours = int(whole / 3600)
	var minutes = int((whole % 3600) / 60)
	var seconds = int(whole % 60)
	return "%02d:%02d:%02d" % [hours, minutes, seconds]

