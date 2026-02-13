extends RefCounted

func on_lightning_strike_pressed(host) -> void:
	if host._environment_controller == null:
		return
	if not host._environment_controller.has_method("trigger_lightning"):
		return
	host._environment_controller.call("trigger_lightning", clampf(float(host._lightning_intensity_spin.value), 0.1, 2.0))

func apply_environment_toggles(host) -> void:
	if host._sun_light != null:
		host._sun_light.shadow_enabled = host._enable_shadows_checkbox.button_pressed
	if host._world_environment == null or host._world_environment.environment == null:
		return
	var env: Environment = host._world_environment.environment
	env.sdfgi_enabled = host._enable_sdfgi_checkbox.button_pressed
	env.glow_enabled = host._enable_glow_checkbox.button_pressed
	host._apply_demo_fog()

func apply_demo_fog(host) -> void:
	if host._world_environment == null or host._world_environment.environment == null:
		return
	var env: Environment = host._world_environment.environment
	var fog_on = host._enable_fog_checkbox.button_pressed
	env.volumetric_fog_enabled = fog_on
	if fog_on:
		env.volumetric_fog_density = 0.02
		env.volumetric_fog_albedo = Color(0.82, 0.87, 0.93, 1.0)
		env.volumetric_fog_emission_energy = 0.02
