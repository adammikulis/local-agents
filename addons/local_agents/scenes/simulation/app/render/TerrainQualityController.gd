extends RefCounted

func on_terrain_chunk_size_changed(host, v: float) -> void:
	if host._environment_controller == null:
		return
	if not host._environment_controller.has_method("set_terrain_chunk_size"):
		return
	host._environment_controller.call("set_terrain_chunk_size", int(round(v)))

func apply_sim_backend_mode(host) -> void:
	match host._sim_backend_option.selected:
		0:
			host._sim_backend_mode = "cpu"
		1:
			host._sim_backend_mode = "gpu_hybrid"
		2:
			host._sim_backend_mode = "gpu_aggressive"
		_:
			host._sim_backend_mode = "ultra"
	var compact = host._sim_backend_mode != "cpu"
	host._ultra_perf_mode = host._sim_backend_mode == "ultra"
	if host._weather != null and host._weather.has_method("set_emit_rows"):
		host._weather.call("set_emit_rows", not compact)
	if host._weather != null and host._weather.has_method("set_compute_enabled"):
		host._weather.call("set_compute_enabled", host._sim_backend_mode == "gpu_aggressive" or host._sim_backend_mode == "ultra")
	if host._erosion != null and host._erosion.has_method("set_emit_rows"):
		host._erosion.call("set_emit_rows", not compact)
	if host._erosion != null and host._erosion.has_method("set_compute_enabled"):
		host._erosion.call("set_compute_enabled", host._sim_backend_mode == "gpu_aggressive" or host._sim_backend_mode == "ultra")
	if host._solar != null and host._solar.has_method("set_emit_rows"):
		host._solar.call("set_emit_rows", not compact)
	if host._solar != null and host._solar.has_method("set_compute_enabled"):
		host._solar.call("set_compute_enabled", host._sim_backend_mode == "gpu_aggressive" or host._sim_backend_mode == "ultra")
	if host._solar != null and host._solar.has_method("set_sync_stride"):
		var sync_stride = 1
		if host._sim_backend_mode == "gpu_hybrid":
			sync_stride = 2
		elif host._sim_backend_mode == "gpu_aggressive":
			sync_stride = 4
		elif host._sim_backend_mode == "ultra":
			sync_stride = 8
		host._solar.call("set_sync_stride", sync_stride)
	if host._sim_backend_mode == "ultra":
		host.max_sim_ticks_per_frame = mini(host.max_sim_ticks_per_frame, 2)
		host.timelapse_record_every_ticks = maxi(8, host.timelapse_record_every_ticks)
		host.flow_overlay_refresh_seconds = maxf(host.flow_overlay_refresh_seconds, 0.5)
		host.terrain_apply_interval_seconds = maxf(host.terrain_apply_interval_seconds, 0.18)
		host.sim_budget_ms_per_frame = minf(host.sim_budget_ms_per_frame, 3.0)
	elif host._sim_backend_mode == "gpu_aggressive":
		host.max_sim_ticks_per_frame = mini(host.max_sim_ticks_per_frame, 3)
		host.timelapse_record_every_ticks = maxi(4, host.timelapse_record_every_ticks)
		host.flow_overlay_refresh_seconds = maxf(host.flow_overlay_refresh_seconds, 0.35)
		host.terrain_apply_interval_seconds = maxf(host.terrain_apply_interval_seconds, 0.12)
		host.sim_budget_ms_per_frame = minf(host.sim_budget_ms_per_frame, 5.0)
	elif compact:
		host.max_sim_ticks_per_frame = mini(host.max_sim_ticks_per_frame, 4)
	else:
		host.max_sim_ticks_per_frame = maxi(host.max_sim_ticks_per_frame, 6)
	host._sim_tick_cap_spin.value = host.max_sim_ticks_per_frame
	host._timelapse_stride_spin.value = host.timelapse_record_every_ticks
	host._flow_refresh_spin.value = host.flow_overlay_refresh_seconds
	host._terrain_apply_spin.value = host.terrain_apply_interval_seconds
	host._sim_budget_ms_spin.value = host.sim_budget_ms_per_frame

func apply_dynamic_quality(host, delta: float) -> void:
	if host._auto_scale_checkbox == null or not host._auto_scale_checkbox.button_pressed:
		return
	host._dynamic_quality_accum += maxf(0.0, delta)
	if host._dynamic_quality_accum < host.dynamic_quality_check_seconds:
		return
	host._dynamic_quality_accum = 0.0
	var fps = Engine.get_frames_per_second()
	if fps <= 0:
		return
	var mode_perf = (host._perf_ewma_by_mode.get(host._sim_backend_mode, {}) as Dictionary)
	var tick_ms = float(mode_perf.get("tick_total_ms", 0.0))
	var target_frame_ms = 1000.0 / maxf(1.0, host.dynamic_target_fps)
	var target_sim_ms = minf(host.sim_budget_ms_per_frame, target_frame_ms * 0.5)
	if tick_ms > 0.0:
		if tick_ms > target_sim_ms * 1.08:
			host._sim_budget_debt_ms += tick_ms - target_sim_ms
			host._sim_budget_credit_ms = maxf(0.0, host._sim_budget_credit_ms - 0.5)
		elif tick_ms < target_sim_ms * 0.82:
			host._sim_budget_credit_ms += target_sim_ms - tick_ms
			host._sim_budget_debt_ms = maxf(0.0, host._sim_budget_debt_ms - 0.5)
	var low_pressure = float(fps) < host.dynamic_target_fps - 6.0 or host._sim_budget_debt_ms > target_sim_ms * 2.0
	var high_pressure = float(fps) > host.dynamic_target_fps + 8.0 and host._sim_budget_credit_ms > target_sim_ms * 2.0
	host._dynamic_pressure_low = host._dynamic_pressure_low + 1 if low_pressure else maxi(0, host._dynamic_pressure_low - 1)
	host._dynamic_pressure_high = host._dynamic_pressure_high + 1 if high_pressure else maxi(0, host._dynamic_pressure_high - 1)
	if host._dynamic_pressure_low >= 2:
		host._dynamic_pressure_low = 0
		if host._ocean_quality_option.selected > 0:
			host._ocean_quality_option.selected -= 1
			host._apply_ocean_quality_preset()
		elif host._cloud_quality_option.selected > 0:
			host._cloud_quality_option.selected -= 1
			host._apply_cloud_and_debug_quality()
		elif host._enable_sdfgi_checkbox.button_pressed:
			host._enable_sdfgi_checkbox.button_pressed = false
			host._apply_environment_toggles()
		elif host._enable_glow_checkbox.button_pressed:
			host._enable_glow_checkbox.button_pressed = false
			host._apply_environment_toggles()
		elif host._enable_shadows_checkbox.button_pressed:
			host._enable_shadows_checkbox.button_pressed = false
			host._apply_environment_toggles()
		host.max_sim_ticks_per_frame = maxi(1, host.max_sim_ticks_per_frame - 1)
		host.sim_budget_ms_per_frame = clampf(host.sim_budget_ms_per_frame - 0.5, 1.0, 25.0)
		host._sim_budget_ms_spin.value = host.sim_budget_ms_per_frame
		host._sim_tick_cap_spin.value = host.max_sim_ticks_per_frame
		host._sim_budget_debt_ms = maxf(0.0, host._sim_budget_debt_ms - target_sim_ms * 0.5)
	elif host._dynamic_pressure_high >= 3:
		host._dynamic_pressure_high = 0
		if host._cloud_quality_option.selected < host._cloud_quality_option.item_count - 1:
			host._cloud_quality_option.selected += 1
			host._apply_cloud_and_debug_quality()
		elif host._ocean_quality_option.selected < host._ocean_quality_option.item_count - 1:
			host._ocean_quality_option.selected += 1
			host._apply_ocean_quality_preset()
		elif not host._enable_shadows_checkbox.button_pressed:
			host._enable_shadows_checkbox.button_pressed = true
			host._apply_environment_toggles()
		elif not host._enable_glow_checkbox.button_pressed:
			host._enable_glow_checkbox.button_pressed = true
			host._apply_environment_toggles()
		elif not host._enable_sdfgi_checkbox.button_pressed:
			host._enable_sdfgi_checkbox.button_pressed = true
			host._apply_environment_toggles()
		host.max_sim_ticks_per_frame = mini(12, host.max_sim_ticks_per_frame + 1)
		host.sim_budget_ms_per_frame = clampf(host.sim_budget_ms_per_frame + 0.5, 1.0, 25.0)
		host._sim_budget_ms_spin.value = host.sim_budget_ms_per_frame
		host._sim_tick_cap_spin.value = host.max_sim_ticks_per_frame
		host._sim_budget_credit_ms = maxf(0.0, host._sim_budget_credit_ms - target_sim_ms * 0.5)
