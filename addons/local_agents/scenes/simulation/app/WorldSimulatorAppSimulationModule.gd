extends "res://addons/local_agents/scenes/simulation/app/WorldSimulatorAppUiModule.gd"

func _step_environment_simulation(delta: float) -> void:
	if not weather_simulation_enabled:
		return
	if _world_snapshot.is_empty() or _hydrology_snapshot.is_empty():
		return
	var tick_duration = 1.0 / maxf(0.1, weather_ticks_per_second)
	_sim_accum += maxf(0.0, delta)
	var terrain_changed = false
	var changed_tiles_map: Dictionary = {}
	var weather_ms_acc = 0.0
	var volcanic_ms_acc = 0.0
	var erosion_ms_acc = 0.0
	var solar_ms_acc = 0.0
	var tick_total_ms_acc = 0.0
	var processed_ticks = 0
	var max_ticks = maxi(1, max_sim_ticks_per_frame)
	var frame_start_us = Time.get_ticks_usec()
	var budget_us = _tick_scheduler.frame_budget_us(sim_budget_ms_per_frame)
	var intervals = _tick_scheduler.intervals_for_mode(_sim_backend_mode)
	var weather_interval = int(intervals.get("weather", 1))
	var erosion_interval = int(intervals.get("erosion", 1))
	var solar_interval = int(intervals.get("solar", 1))
	var async_weather_result = _consume_weather_worker_result()
	if not async_weather_result.is_empty():
		_weather_snapshot = async_weather_result.get("snapshot", _weather_snapshot)
		weather_ms_acc += float(async_weather_result.get("step_ms", 0.0))
	var async_erosion_result = _consume_erosion_worker_result()
	if not async_erosion_result.is_empty():
		_world_snapshot = async_erosion_result.get("environment", _world_snapshot)
		_hydrology_snapshot = async_erosion_result.get("hydrology", _hydrology_snapshot)
		_erosion_snapshot = async_erosion_result.get("erosion", _erosion_snapshot)
		erosion_ms_acc += float(async_erosion_result.get("step_ms", 0.0))
		terrain_changed = terrain_changed or bool(async_erosion_result.get("changed", false))
		for tile_variant in async_erosion_result.get("changed_tiles", []):
			var tile_id = String(tile_variant)
			changed_tiles_map[tile_id] = true
			_pending_terrain_changed_tiles[tile_id] = true
	var async_solar_result = _consume_solar_worker_result()
	if not async_solar_result.is_empty():
		_solar_snapshot = async_solar_result.get("snapshot", _solar_snapshot)
		solar_ms_acc += float(async_solar_result.get("step_ms", 0.0))
		_solar_snapshot["seed"] = _solar_seed
	while _sim_accum >= tick_duration and processed_ticks < max_ticks:
		var tick_start_us = Time.get_ticks_usec()
		_sim_accum -= tick_duration
		processed_ticks += 1
		_sim_tick += 1
		_simulated_seconds += tick_duration
		_weather_tick_accum += tick_duration
		_erosion_tick_accum += tick_duration
		_solar_tick_accum += tick_duration
		var local_activity = _build_local_activity_field()
		if _tick_scheduler.should_step_subsystem(_sim_tick, weather_interval, _weather_snapshot.is_empty()):
			var weather_compute_active = _weather != null and _weather.has_method("is_compute_active") and bool(_weather.call("is_compute_active"))
			if (_sim_backend_mode == "gpu_aggressive" or _sim_backend_mode == "ultra") and not weather_compute_active and not _weather_thread_busy:
				_start_weather_worker(_sim_tick, _weather_tick_accum, local_activity)
				_weather_tick_accum = 0.0
			elif not _weather_thread_busy:
				var weather_start_us = Time.get_ticks_usec()
				_weather_snapshot = _weather.step(_sim_tick, _weather_tick_accum, local_activity)
				_weather_tick_accum = 0.0
				weather_ms_acc += float(Time.get_ticks_usec() - weather_start_us) / 1000.0
		var volcanic_start_us = Time.get_ticks_usec()
		var volcanic_change = _step_volcanic_island_growth(tick_duration)
		volcanic_ms_acc += float(Time.get_ticks_usec() - volcanic_start_us) / 1000.0
		if bool(volcanic_change.get("changed", false)):
			terrain_changed = true
			for tile_variant in volcanic_change.get("changed_tiles", []):
				var tile_id = String(tile_variant)
				changed_tiles_map[tile_id] = true
				_pending_terrain_changed_tiles[tile_id] = true
		if _tick_scheduler.should_step_subsystem(_sim_tick, erosion_interval, false):
			var erosion_compute_active = _erosion != null and _erosion.has_method("is_compute_active") and bool(_erosion.call("is_compute_active"))
			if (_sim_backend_mode == "gpu_aggressive" or _sim_backend_mode == "ultra") and not erosion_compute_active and not _erosion_thread_busy:
				_start_erosion_worker(_sim_tick, _erosion_tick_accum, local_activity)
				_erosion_tick_accum = 0.0
			elif not _erosion_thread_busy:
				var erosion_start_us = Time.get_ticks_usec()
				var erosion_result: Dictionary = _erosion.step(
					_sim_tick,
					_erosion_tick_accum,
					_world_snapshot,
					_hydrology_snapshot,
					_weather_snapshot,
					local_activity
				)
				erosion_ms_acc += float(Time.get_ticks_usec() - erosion_start_us) / 1000.0
				_erosion_tick_accum = 0.0
				_world_snapshot = erosion_result.get("environment", _world_snapshot)
				_hydrology_snapshot = erosion_result.get("hydrology", _hydrology_snapshot)
				_erosion_snapshot = erosion_result.get("erosion", _erosion_snapshot)
				terrain_changed = terrain_changed or bool(erosion_result.get("changed", false))
				var changed_tiles: Array = erosion_result.get("changed_tiles", [])
				for tile_variant in changed_tiles:
					var tile_id = String(tile_variant)
					changed_tiles_map[tile_id] = true
					_pending_terrain_changed_tiles[tile_id] = true
		if _tick_scheduler.should_step_subsystem(_sim_tick, solar_interval, false):
			var solar_compute_active = _solar != null and _solar.has_method("is_compute_active") and bool(_solar.call("is_compute_active"))
			if (_sim_backend_mode == "gpu_aggressive" or _sim_backend_mode == "ultra") and not solar_compute_active and not _solar_thread_busy:
				_start_solar_worker(_sim_tick, _solar_tick_accum, local_activity)
				_solar_tick_accum = 0.0
			elif not _solar_thread_busy:
				var solar_start_us = Time.get_ticks_usec()
				_solar_snapshot = _solar.step(_sim_tick, _solar_tick_accum, _world_snapshot, _weather_snapshot, local_activity)
				solar_ms_acc += float(Time.get_ticks_usec() - solar_start_us) / 1000.0
				_solar_tick_accum = 0.0
				_solar_snapshot["seed"] = _solar_seed
		if _sim_tick % maxi(1, timelapse_record_every_ticks) == 0:
			_record_timelapse_snapshot(_sim_tick)
		tick_total_ms_acc += float(Time.get_ticks_usec() - tick_start_us) / 1000.0
		if Time.get_ticks_usec() - frame_start_us >= budget_us:
			break
	_water_renderer.apply_state(_environment_controller, _weather_snapshot, _solar_snapshot)
	_sync_living_world_features(false)
	_apply_water_shader_controls()
	_terrain_apply_accum += maxf(0.0, delta)
	_flow_overlay_accum += maxf(0.0, delta)
	var must_apply_now = _pending_terrain_changed_tiles.size() >= 256
	var apply_interval = maxf(0.0, terrain_apply_interval_seconds)
	if _ultra_perf_mode:
		apply_interval = maxf(0.22, apply_interval)
	var should_apply = not _pending_terrain_changed_tiles.is_empty() and (must_apply_now or apply_interval <= 0.0 or _terrain_apply_accum >= apply_interval)
	var did_apply = false
	if should_apply and _environment_controller.has_method("apply_generation_delta"):
		var apply_start_us = Time.get_ticks_usec()
		_terrain_renderer.apply_delta(_environment_controller, _world_snapshot, _hydrology_snapshot, _pending_terrain_changed_tiles.keys())
		_pending_terrain_changed_tiles.clear()
		_terrain_apply_accum = 0.0
		did_apply = true
		_flow_overlay_dirty = true
		_perf_record("terrain_apply_ms", float(Time.get_ticks_usec() - apply_start_us) / 1000.0)
	elif should_apply and _environment_controller.has_method("apply_generation_data"):
		var apply_full_start_us = Time.get_ticks_usec()
		_terrain_renderer.apply_generation(_environment_controller, _world_snapshot, _hydrology_snapshot, int(round(_terrain_chunk_spin.value)))
		_pending_terrain_changed_tiles.clear()
		_terrain_apply_accum = 0.0
		did_apply = true
		_flow_overlay_dirty = true
		_perf_record("terrain_apply_ms", float(Time.get_ticks_usec() - apply_full_start_us) / 1000.0)
	if _show_flow_checkbox.button_pressed:
		var flow_interval = maxf(0.02, flow_overlay_refresh_seconds)
		if _ultra_perf_mode:
			flow_interval = maxf(flow_interval, 0.6)
		if did_apply or _flow_overlay_accum >= flow_interval:
			var config = _current_worldgen_config()
			_render_flow_overlay(_world_snapshot, config)
			_flow_overlay_accum = 0.0
	if processed_ticks > 0:
		var inv = 1.0 / float(processed_ticks)
		_perf_record("weather_ms", weather_ms_acc * inv)
		_perf_record("volcanic_ms", volcanic_ms_acc * inv)
		_perf_record("erosion_ms", erosion_ms_acc * inv)
		_perf_record("solar_ms", solar_ms_acc * inv)
		_perf_record("tick_total_ms", tick_total_ms_acc * inv)
	var slides: Array = _erosion_snapshot.get("recent_landslides", [])
	_landslide_count = slides.size()
	_update_stats(_world_snapshot, _hydrology_snapshot, int(hash(_seed_line_edit.text.strip_edges())))
	_push_state_from_runtime()

func _step_volcanic_island_growth(tick_duration: float) -> Dictionary:
	var eruption_interval = maxf(0.1, float(_eruption_interval_spin.value)) if _eruption_interval_spin != null else maxf(0.1, eruption_interval_seconds)
	var new_vent_chance = clampf(float(_new_vent_chance_spin.value), 0.0, 1.0) if _new_vent_chance_spin != null else clampf(new_vent_spawn_chance, 0.0, 1.0)
	var island_growth = maxf(0.0, float(_island_growth_spin.value)) if _island_growth_spin != null else island_growth_per_eruption
	var result = _volcanic.step(
		_world_snapshot,
		_sim_tick,
		tick_duration,
		_ticks_per_frame,
		eruption_interval,
		new_vent_chance,
		island_growth,
		_manual_eruption_active,
		_manual_selected_vent_tile_id,
		hydrology_rebake_every_eruption_events,
		hydrology_rebake_max_seconds,
		Callable(self, "_spawn_lava_plume")
	)
	_world_snapshot = result.get("world", _world_snapshot)
	_manual_selected_vent_tile_id = String(result.get("selected_tile_id", _manual_selected_vent_tile_id))
	var pending = _volcanic.pending_state()
	_pending_hydro_rebake_events = int(pending.get("events", _pending_hydro_rebake_events))
	_pending_hydro_rebake_seconds = float(pending.get("seconds", _pending_hydro_rebake_seconds))
	_pending_hydro_changed_tiles = (pending.get("tiles", {}) as Dictionary).duplicate(true)
	if bool(result.get("rebake_due", false)):
		_rebake_hydrology_from_pending()
	_refresh_manual_vent_status()
	return {
		"changed": bool(result.get("changed", false)),
		"changed_tiles": result.get("changed_tiles", []),
	}


func _rebake_hydrology_from_pending() -> void:
	if _pending_hydro_rebake_events <= 0 and _pending_hydro_changed_tiles.is_empty():
		return
	_stop_async_workers()
	var config = _current_worldgen_config()
	_world_snapshot["flow_map"] = _world_generator.rebake_flow_map(_world_snapshot)
	_hydrology_snapshot = _hydrology.build_network(_world_snapshot, config)
	_weather.configure_environment(_world_snapshot, _hydrology_snapshot, int(_weather_snapshot.get("seed", 0)))
	_erosion.configure_environment(_world_snapshot, _hydrology_snapshot, int(_erosion_snapshot.get("seed", 0)))
	_solar.configure_environment(_world_snapshot, _solar_seed)
	_pending_hydro_changed_tiles.clear()
	_pending_hydro_rebake_events = 0
	_pending_hydro_rebake_seconds = 0.0
	_volcanic.clear_pending_rebake()
	_flow_overlay_dirty = true


func _record_timelapse_snapshot(tick: int) -> void:
	var snapshot_resource = VoxelTimelapseSnapshotResourceScript.new()
	snapshot_resource.tick = tick
	snapshot_resource.time_of_day = _time_of_day
	snapshot_resource.simulated_year = _year_at_tick(tick)
	snapshot_resource.simulated_seconds = _simulated_seconds
	snapshot_resource.world = _world_snapshot.duplicate(true)
	snapshot_resource.hydrology = _hydrology_snapshot.duplicate(true)
	snapshot_resource.weather = _weather_snapshot.duplicate(true)
	snapshot_resource.erosion = _erosion_snapshot.duplicate(true)
	snapshot_resource.solar = _solar_snapshot.duplicate(true)
	_timelapse_snapshots[tick] = snapshot_resource
	var keys = _timelapse_snapshots.keys()
	var max_snapshots = 192 if _ultra_perf_mode else 480
	if keys.size() <= max_snapshots:
		return
	keys.sort()
	var drop_count = keys.size() - max_snapshots
	for i in range(drop_count):
		_timelapse_snapshots.erase(keys[i])


func _restore_to_tick(target_tick: int) -> void:
	if _timelapse_snapshots.is_empty():
		return
	_stop_async_workers()
	_clear_lava_fx()
	_pending_hydro_changed_tiles.clear()
	_pending_hydro_rebake_events = 0
	_pending_hydro_rebake_seconds = 0.0
	_volcanic.reset()
	_pending_terrain_changed_tiles.clear()
	_flow_overlay_accum = flow_overlay_refresh_seconds
	_terrain_apply_accum = terrain_apply_interval_seconds
	_flow_overlay_dirty = true
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
	var snapshot_variant = _timelapse_snapshots.get(selected_tick, null)
	if snapshot_variant == null:
		return
	var snapshot_dict: Dictionary = {}
	if snapshot_variant is Resource and snapshot_variant.has_method("to_dict"):
		snapshot_dict = snapshot_variant.to_dict()
	elif snapshot_variant is Dictionary:
		snapshot_dict = (snapshot_variant as Dictionary).duplicate(true)
	if snapshot_dict.is_empty():
		return
	_sim_tick = int(snapshot_dict.get("tick", selected_tick))
	_simulated_seconds = maxf(0.0, float(snapshot_dict.get("simulated_seconds", float(_sim_tick) / maxf(0.1, weather_ticks_per_second))))
	_time_of_day = clampf(float(snapshot_dict.get("time_of_day", _time_of_day)), 0.0, 1.0)
	_world_snapshot = snapshot_dict.get("world", {}).duplicate(true)
	_hydrology_snapshot = snapshot_dict.get("hydrology", {}).duplicate(true)
	_weather_snapshot = snapshot_dict.get("weather", {}).duplicate(true)
	_erosion_snapshot = snapshot_dict.get("erosion", {}).duplicate(true)
	_solar_snapshot = snapshot_dict.get("solar", {}).duplicate(true)
	_solar_seed = int(_solar_snapshot.get("seed", 0))
	_weather.configure_environment(_world_snapshot, _hydrology_snapshot, int(_weather_snapshot.get("seed", 0)))
	_weather.import_snapshot(_weather_snapshot)
	_erosion.configure_environment(_world_snapshot, _hydrology_snapshot, int(_erosion_snapshot.get("seed", 0)))
	_erosion.import_snapshot(_erosion_snapshot)
	_solar.configure_environment(_world_snapshot, _solar_seed)
	_solar.import_snapshot(_solar_snapshot)
	var slides: Array = _erosion_snapshot.get("recent_landslides", [])
	_landslide_count = slides.size()
	if _environment_controller.has_method("apply_generation_data"):
		_terrain_renderer.apply_generation(_environment_controller, _world_snapshot, _hydrology_snapshot, int(round(_terrain_chunk_spin.value)))
	if _show_flow_checkbox.button_pressed:
		_render_flow_overlay(_world_snapshot, _current_worldgen_config())
	_water_renderer.apply_state(_environment_controller, _weather_snapshot, _solar_snapshot)
	_sync_living_world_features(true)
	_apply_water_shader_controls()
	_update_stats(_world_snapshot, _hydrology_snapshot, int(hash(_seed_line_edit.text.strip_edges())))
	_push_state_from_runtime()


func _stop_async_workers() -> void:
	_stop_weather_worker()
	_stop_erosion_worker()
	_stop_solar_worker()

func _stop_weather_worker() -> void:
	if _weather_thread != null and _weather_thread.is_alive():
		_weather_thread.wait_to_finish()
	_weather_thread = null
	_weather_thread_busy = false
	_weather_thread_mutex.lock()
	_weather_thread_result = {}
	_weather_thread_mutex.unlock()

func _stop_erosion_worker() -> void:
	if _erosion_thread != null and _erosion_thread.is_alive():
		_erosion_thread.wait_to_finish()
	_erosion_thread = null
	_erosion_thread_busy = false
	_erosion_thread_mutex.lock()
	_erosion_thread_result = {}
	_erosion_thread_mutex.unlock()

func _start_erosion_worker(tick: int, delta: float, local_activity: Dictionary) -> void:
	if _erosion_thread_busy:
		return
	var world_copy = _world_snapshot.duplicate(true)
	var hydro_copy = _hydrology_snapshot.duplicate(true)
	var weather_copy = _weather_snapshot.duplicate(true)
	if _erosion_thread == null:
		_erosion_thread = Thread.new()
	_erosion_thread_busy = true
	var callable = Callable(self, "_erosion_thread_entry").bind(tick, delta, world_copy, hydro_copy, weather_copy, local_activity.duplicate(true))
	_erosion_thread.start(callable)

func _erosion_thread_entry(tick: int, delta: float, world_copy: Dictionary, hydro_copy: Dictionary, weather_copy: Dictionary, local_activity: Dictionary) -> void:
	var result = _erosion.step(tick, delta, world_copy, hydro_copy, weather_copy, local_activity)
	_erosion_thread_mutex.lock()
	_erosion_thread_result = result
	_erosion_thread_mutex.unlock()

func _consume_erosion_worker_result() -> Dictionary:
	if not _erosion_thread_busy:
		return {}
	if _erosion_thread != null and _erosion_thread.is_alive():
		return {}
	if _erosion_thread != null:
		_erosion_thread.wait_to_finish()
	_erosion_thread_busy = false
	_erosion_thread_mutex.lock()
	var result = _erosion_thread_result.duplicate(true)
	_erosion_thread_result = {}
	_erosion_thread_mutex.unlock()
	return result

func _stop_solar_worker() -> void:
	if _solar_thread != null and _solar_thread.is_alive():
		_solar_thread.wait_to_finish()
	_solar_thread = null
	_solar_thread_busy = false
	_solar_thread_mutex.lock()
	_solar_thread_result = {}
	_solar_thread_mutex.unlock()

func _start_weather_worker(tick: int, delta: float, local_activity: Dictionary) -> void:
	if _weather_thread_busy:
		return
	if _weather_thread == null:
		_weather_thread = Thread.new()
	_weather_thread_busy = true
	var callable = Callable(self, "_weather_thread_entry").bind(tick, delta, local_activity.duplicate(true))
	_weather_thread.start(callable)

func _weather_thread_entry(tick: int, delta: float, local_activity: Dictionary) -> void:
	var start_us = Time.get_ticks_usec()
	var snapshot = _weather.step(tick, delta, local_activity)
	var elapsed_ms = float(Time.get_ticks_usec() - start_us) / 1000.0
	_weather_thread_mutex.lock()
	_weather_thread_result = {"snapshot": snapshot, "step_ms": elapsed_ms}
	_weather_thread_mutex.unlock()

func _consume_weather_worker_result() -> Dictionary:
	if not _weather_thread_busy:
		return {}
	if _weather_thread != null and _weather_thread.is_alive():
		return {}
	if _weather_thread != null:
		_weather_thread.wait_to_finish()
	_weather_thread_busy = false
	_weather_thread_mutex.lock()
	var result = _weather_thread_result.duplicate(true)
	_weather_thread_result = {}
	_weather_thread_mutex.unlock()
	return result

func _start_solar_worker(tick: int, delta: float, local_activity: Dictionary) -> void:
	if _solar_thread_busy:
		return
	var world_copy = _world_snapshot.duplicate(true)
	var weather_copy = _weather_snapshot.duplicate(true)
	if _solar_thread == null:
		_solar_thread = Thread.new()
	_solar_thread_busy = true
	var callable = Callable(self, "_solar_thread_entry").bind(tick, delta, world_copy, weather_copy, local_activity.duplicate(true))
	_solar_thread.start(callable)

func _solar_thread_entry(tick: int, delta: float, world_copy: Dictionary, weather_copy: Dictionary, local_activity: Dictionary) -> void:
	var start_us = Time.get_ticks_usec()
	var snapshot = _solar.step(tick, delta, world_copy, weather_copy, local_activity)
	var elapsed_ms = float(Time.get_ticks_usec() - start_us) / 1000.0
	_solar_thread_mutex.lock()
	_solar_thread_result = {"snapshot": snapshot, "step_ms": elapsed_ms}
	_solar_thread_mutex.unlock()

func _consume_solar_worker_result() -> Dictionary:
	if not _solar_thread_busy:
		return {}
	if _solar_thread != null and _solar_thread.is_alive():
		return {}
	if _solar_thread != null:
		_solar_thread.wait_to_finish()
	_solar_thread_busy = false
	_solar_thread_mutex.lock()
	var result = _solar_thread_result.duplicate(true)
	_solar_thread_result = {}
	_solar_thread_mutex.unlock()
	return result

func _build_local_activity_field() -> Dictionary:
	var next: Dictionary = {}
	for tile_variant in _local_activity_by_tile.keys():
		var tile_id = String(tile_variant)
		var decayed = clampf(float(_local_activity_by_tile.get(tile_id, 0.0)) * 0.9, 0.0, 1.0)
		if decayed > 0.01:
			next[tile_id] = decayed
	for tile_variant in _pending_terrain_changed_tiles.keys():
		var tile_id = String(tile_variant)
		next[tile_id] = maxf(float(next.get(tile_id, 0.0)), 0.75)
	var erosion_changed: Array = _erosion_snapshot.get("changed_tiles", [])
	for tile_variant in erosion_changed:
		var tile_id = String(tile_variant)
		next[tile_id] = maxf(float(next.get(tile_id, 0.0)), 0.6)
	var geology: Dictionary = _world_snapshot.get("geology", {})
	var volcanoes: Array = geology.get("volcanic_features", [])
	for volcano_variant in volcanoes:
		if not (volcano_variant is Dictionary):
			continue
		var volcano = volcano_variant as Dictionary
		var vx = int(volcano.get("x", 0))
		var vz = int(volcano.get("y", 0))
		var radius = maxi(1, int(volcano.get("radius", 2)))
		var activity = clampf(float(volcano.get("activity", 0.5)), 0.0, 1.0)
		for dz in range(-radius - 1, radius + 2):
			for dx in range(-radius - 1, radius + 2):
				var tx = vx + dx
				var tz = vz + dz
				if tx < 0 or tz < 0 or tx >= int(_world_snapshot.get("width", 0)) or tz >= int(_world_snapshot.get("height", 0)):
					continue
				var dist = sqrt(float(dx * dx + dz * dz))
				var max_dist = float(radius) + 1.0
				if dist > max_dist:
					continue
				var falloff = clampf(1.0 - dist / max_dist, 0.0, 1.0)
				var tile_id = TileKeyUtilsScript.tile_id(tx, tz)
				var score = clampf(activity * (0.35 + falloff * 0.65), 0.0, 1.0)
				next[tile_id] = maxf(float(next.get(tile_id, 0.0)), score)
	_local_activity_by_tile = next
	return next.duplicate(true)


func _sync_living_world_features(force_respawn_settlement: bool) -> void:
	var signals = {
		"environment_snapshot": _world_snapshot,
		"water_network_snapshot": _hydrology_snapshot,
		"weather_snapshot": _weather_snapshot,
		"solar_snapshot": _solar_snapshot,
	}
	if _ecology_controller != null and _ecology_controller.has_method("set_environment_signals"):
		_ecology_controller.call("set_environment_signals", signals)
	if force_respawn_settlement and _settlement_controller != null and _settlement_controller.has_method("spawn_initial_settlement"):
		var width = float(_world_snapshot.get("width", 1))
		var depth = float(_world_snapshot.get("height", 1))
		var spawn = {"chosen": {"x": width * 0.5, "y": depth * 0.5}}
		_settlement_controller.call("spawn_initial_settlement", spawn)
	if force_respawn_settlement and _villager_controller != null and _villager_controller.has_method("clear_generated"):
		_villager_controller.call("clear_generated")

func _on_hud_overlays_changed(paths: bool, resources: bool, conflicts: bool, smell: bool, wind: bool, temperature: bool) -> void:
	_overlay_renderer.apply_visibility(_debug_overlay_root, paths, resources, conflicts, smell, wind, temperature)
