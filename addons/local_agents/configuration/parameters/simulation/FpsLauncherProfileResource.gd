extends Resource
class_name LocalAgentsFpsLauncherProfileResource

@export var launch_speed: float = 60.0
@export var launch_mass: float = 0.2
@export var projectile_radius: float = 0.07
@export var projectile_ttl_seconds: float = 4.0
@export var launch_energy_scale: float = 1.0

func to_dict() -> Dictionary:
	return {
		"launch_speed": launch_speed,
		"launch_mass": launch_mass,
		"projectile_radius": projectile_radius,
		"projectile_ttl_seconds": projectile_ttl_seconds,
		"launch_energy_scale": launch_energy_scale,
	}

