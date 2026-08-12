class_name LAEcologyAquatic
extends RefCounted


const AQUATIC_SAMPLE_TRIES: int = 60

var _eco: LAEcologyService = null


func setup(eco: LAEcologyService) -> void:
	_eco = eco


# Seed a modest starting population of every aquatic species into water matching its band. Called once
# after the sea level is locked. Ongoing recovery is handled by _tick_aquatic; this just makes the sea
# and lakes feel alive from the first frame instead of trickling in.
func stock_initial_aquatic() -> void:
	for kind in _eco._aquatic_kinds():
		var cfg: Dictionary = _eco._species_config(String(kind))
		var initial: int = int(round(float(cfg.get("initial", 0)) * LAEcologyService.AQUATIC_STOCK_MULT))
		for i in range(initial):
			var wet: Vector3 = _random_aquatic_point(cfg)
			if not is_nan(wet.x):
				_eco._instance_actor(String(kind), wet)


func _random_aquatic_point(cfg: Dictionary) -> Vector3:
	var dmin: float = float(cfg.get("depth_min", 0.0))
	var dmax: float = float(cfg.get("depth_max", 999.0))
	var pc: Vector3 = _eco.terrain.planet_center()
	var sea_r: float = _eco.terrain.sea_radius()
	for i in range(AQUATIC_SAMPLE_TRIES):
		var dir: Vector3 = LAEcologySpawner._random_sphere_dir()
		var ground_r: float = _eco.terrain.surface_radius(dir)
		if is_nan(ground_r) or ground_r >= sea_r:
			continue                                  # unmeshed, or dry land poking above sea level
		var lo: float = maxf(ground_r, sea_r - dmax)  # deepest allowed (clamped to just above the seabed)
		var hi: float = sea_r - dmin                  # shallowest allowed (just below the surface)
		if hi <= lo:
			continue
		return pc + dir * LASimRng.shared().randf_range(lo, hi)
	return Vector3(NAN, 0.0, 0.0)
