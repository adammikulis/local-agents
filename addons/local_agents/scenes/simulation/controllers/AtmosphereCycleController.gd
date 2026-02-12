extends RefCounted
class_name LocalAgentsAtmosphereCycleController

func advance_time(current_time_of_day: float, delta: float, enabled: bool, day_length_seconds: float) -> float:
	if not enabled:
		return clampf(current_time_of_day, 0.0, 1.0)
	var day_len = maxf(5.0, day_length_seconds)
	return fposmod(current_time_of_day + delta / day_len, 1.0)

func apply_to_light_and_environment(
	time_of_day: float,
	light: DirectionalLight3D,
	world_environment: WorldEnvironment,
	energy_night: float,
	energy_day: float,
	indirect_night: float,
	indirect_day: float,
	ambient_night: float,
	ambient_day: float,
	background_night: float,
	background_day: float
) -> Dictionary:
	if light == null:
		return {"daylight": 0.0}
	var phase = time_of_day * TAU
	var elevation_sin = sin(phase - PI * 0.5)
	var daylight = clampf((elevation_sin + 1.0) * 0.5, 0.0, 1.0)
	var elevation = deg_to_rad(lerpf(-12.0, 82.0, daylight))
	var azimuth = phase - PI * 0.5
	var dir = Vector3(
		cos(elevation) * cos(azimuth),
		sin(elevation),
		cos(elevation) * sin(azimuth)
	).normalized()
	light.look_at(light.global_position + dir, Vector3.UP)
	light.light_energy = lerpf(energy_night, energy_day, pow(daylight, 1.45))
	light.light_indirect_energy = lerpf(indirect_night, indirect_day, pow(daylight, 1.35))
	light.light_color = Color(
		lerpf(0.3, 1.0, daylight),
		lerpf(0.38, 0.96, daylight),
		lerpf(0.62, 0.9, daylight),
		1.0
	)
	if world_environment != null and world_environment.environment != null:
		world_environment.environment.ambient_light_energy = lerpf(ambient_night, ambient_day, pow(daylight, 1.25))
		world_environment.environment.background_energy_multiplier = lerpf(background_night, background_day, pow(daylight, 1.2))
	return {"daylight": daylight}
