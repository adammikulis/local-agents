extends RefCounted

func apply_ocean_quality_preset(host) -> void:
	match host._ocean_quality_option.selected:
		0:
			host.tide_uniform_updates_per_second = 2.0
			host._ocean_detail = 0.35
		1:
			host.tide_uniform_updates_per_second = 6.0
			host._ocean_detail = 0.66
		2:
			host.tide_uniform_updates_per_second = 10.0
			host._ocean_detail = 0.82
		_:
			host.tide_uniform_updates_per_second = 16.0
			host._ocean_detail = 1.0
	host._apply_tide_shader_controls(true)

func apply_water_shader_controls(host) -> void:
	if host._environment_controller == null:
		return
	if not host._environment_controller.has_method("set_water_shader_params"):
		return
	var flow_dir = Vector2(host._water_flow_dir_x_spin.value, host._water_flow_dir_z_spin.value)
	if flow_dir.length_squared() < 0.0001:
		flow_dir = Vector2(1.0, 0.0)
	var params = {
		"flow_dir": flow_dir.normalized(),
		"flow_speed": host._water_flow_speed_spin.value,
		"noise_scale": host._water_noise_scale_spin.value,
		"foam_strength": host._water_foam_strength_spin.value,
		"wave_strength": host._water_wave_strength_spin.value,
	}
	params.merge(build_tide_shader_params(host), true)
	host._water_renderer.apply_shader_params(host._environment_controller, params)

func apply_tide_shader_controls(host, force: bool = false) -> void:
	if host._environment_controller == null:
		return
	if not host._environment_controller.has_method("set_water_shader_params"):
		return
	var update_interval = 1.0 / maxf(1.0, host.tide_uniform_updates_per_second)
	if not force and host._tide_uniform_accum < update_interval:
		return
	host._tide_uniform_accum = 0.0
	var params = build_tide_shader_params(host)
	var signature = "%.3f|%.3f|%.3f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f" % [
		float(params.get("moon_phase", 0.0)),
		float((params.get("moon_dir", Vector2.ONE) as Vector2).x),
		float((params.get("moon_dir", Vector2.ONE) as Vector2).y),
		float(params.get("moon_tidal_strength", 0.0)),
		float(params.get("moon_tide_range", 0.0)),
		float(params.get("lunar_wave_boost", 0.0)),
		float(params.get("gravity_source_strength", 0.0)),
		float(params.get("gravity_source_radius", 0.0)),
		float(params.get("ocean_wave_amplitude", 0.0)),
		float(params.get("ocean_wave_frequency", 0.0)),
		float(params.get("ocean_chop", 0.0)),
		float((params.get("gravity_source_pos", Vector2.ZERO) as Vector2).x),
		float((params.get("gravity_source_pos", Vector2.ZERO) as Vector2).y),
	]
	if not force and signature == host._tide_uniform_signature:
		return
	host._tide_uniform_signature = signature
	host._water_renderer.apply_shader_params(host._environment_controller, params)

func build_tide_shader_params(host) -> Dictionary:
	var cycle_days = maxf(1.0, float(host._moon_cycle_days_spin.value)) if host._moon_cycle_days_spin != null else host.lunar_cycle_days
	var lunar_period_seconds = maxf(1.0, cycle_days * maxf(10.0, host.day_length_seconds))
	var moon_phase = fposmod(host._simulated_seconds, lunar_period_seconds) / lunar_period_seconds
	var moon_angle = moon_phase * TAU
	var moon_dir = Vector2(cos(moon_angle), sin(moon_angle))
	if moon_dir.length_squared() < 0.0001:
		moon_dir = Vector2(1.0, 0.0)
	var world_width = float(host._world_snapshot.get("width", int(host._width_spin.value)))
	var world_depth = float(host._world_snapshot.get("height", int(host._depth_spin.value)))
	var camera_pos = host._camera.global_position if host._camera != null else Vector3.ZERO
	var far_start = maxf(world_width, world_depth) * 0.35
	var far_end = maxf(world_width, world_depth) * 1.2
	var gravity_orbit = maxf(world_width, world_depth) * 0.55
	var gravity_pos = Vector2(world_width * 0.5, world_depth * 0.5) + moon_dir * gravity_orbit
	var spring_neap = absf(cos(moon_phase * TAU))
	return {
		"moon_dir": moon_dir.normalized(),
		"moon_phase": moon_phase,
		"moon_tidal_strength": float(host._moon_tide_strength_spin.value) if host._moon_tide_strength_spin != null else 1.0,
		"moon_tide_range": float(host._moon_tide_range_spin.value) if host._moon_tide_range_spin != null else 0.26,
		"lunar_wave_boost": lerpf(0.25, 1.0, spring_neap),
		"gravity_source_pos": gravity_pos,
		"gravity_source_strength": float(host._gravity_strength_spin.value) if host._gravity_strength_spin != null else 1.0,
		"gravity_source_radius": float(host._gravity_radius_spin.value) if host._gravity_radius_spin != null else 96.0,
		"ocean_wave_amplitude": float(host._ocean_amplitude_spin.value) if host._ocean_amplitude_spin != null else 0.18,
		"ocean_wave_frequency": float(host._ocean_frequency_spin.value) if host._ocean_frequency_spin != null else 0.65,
		"ocean_chop": float(host._ocean_chop_spin.value) if host._ocean_chop_spin != null else 0.55,
		"ocean_detail": host._ocean_detail,
		"camera_world_pos": camera_pos,
		"far_simplify_start": float(host._water_lod_start_spin.value) if host._water_lod_start_spin != null else far_start,
		"far_simplify_end": float(host._water_lod_end_spin.value) if host._water_lod_end_spin != null else far_end,
		"far_detail_min": float(host._water_lod_min_spin.value) if host._water_lod_min_spin != null else 0.28,
	}
