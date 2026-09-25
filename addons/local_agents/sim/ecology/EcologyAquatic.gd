class_name LAEcologyAquatic
extends RefCounted


const AQUATIC_SAMPLE_TRIES: int = 60

var _eco: LAEcologyService = null


func setup(eco: LAEcologyService) -> void:
	_eco = eco


# Seed a modest starting population of every aquatic species into water matching its band. Called once
# after the field holds its water. Ongoing recovery is handled by _tick_aquatic; this just makes the
# water feel alive from the first frame instead of trickling in.
func stock_initial_aquatic() -> void:
	for kind in _eco._aquatic_kinds():
		var cfg: Dictionary = _eco._species_config(String(kind))
		var initial: int = int(cfg.get("initial", 0))
		for i in range(initial):
			var wet: Vector3 = _random_aquatic_point(cfg)
			if not is_nan(wet.x):
				_eco._instance_actor(String(kind), wet)


func _random_aquatic_point(cfg: Dictionary) -> Vector3:
	var dmin: float = float(cfg.get("depth_min", 0.0))
	var dmax: float = float(cfg.get("depth_max", 999.0))
	var pc: Vector3 = _eco.terrain.planet_center()
	for i in range(AQUATIC_SAMPLE_TRIES):
		var dir: Vector3 = _eco.random_field_dir()
		var ground_r: float = _eco._surface_radius(dir)
		var surf: float = _eco._material.water_surface_along(dir) if _eco._material != null else NAN
		if is_nan(ground_r) or is_nan(surf):
			continue                                  # dry land: no water stands over it
		var lo: float = maxf(ground_r, surf - dmax)   # deepest allowed (clamped to just above the bed)
		var hi: float = surf - dmin                   # shallowest allowed (just below the surface)
		if hi <= lo:
			continue
		return pc + dir * LASimRng.for_domain("life").randf_range(lo, hi)
	return Vector3(NAN, 0.0, 0.0)
