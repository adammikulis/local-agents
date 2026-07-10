class_name LAEcologyAquatic
extends RefCounted

## Aquatic placement for the living world — the non-reproduction water helpers: the initial founding stock
## that makes the sea and lakes feel alive from the first frame, and the salinity/depth-band sampler that
## finds a valid underwater point for a species. Everything is radial (no XZ column reads — three-d-always),
## so species self-sort into the right water with no hand-placed spawn points.
##
## Aquatic REPRODUCTION (the parent-based _tick_aquatic recovery) is inseparable from the land breeding
## machinery, so it lives in LAEcologyBreeding alongside _tick_breeding; this module owns only the non-repro
## spawn/placement helpers. Owned by LAEcologyService, which keeps a thin forwarder for the public
## stock_initial_aquatic() and for _random_aquatic_point() (which the breeding module reaches through the
## hub). This module reaches back into the service for the shared state that stays on the hub — the aquatic
## roster, species configs, terrain and the actor instancer — so there is exactly one owner of each.
## Explicit types only (project rule: no ':=').

# Aquatic sampling budget: tries per placement to land inside a species' salinity/depth band (radial).
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


# Sample the sea for a point inside a species' depth band: pick a random direction where the GROUND surface
# sits below sea level, then place the individual somewhere in the underwater shell between the seabed and the
# sea radius, inside the species' depth band. Everything is radial (no XZ column reads — three-d-always), so
# species self-sort into the right water with no hand-placed spawn points. NAN-x vector if none found.
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
		return pc + dir * randf_range(lo, hi)
	return Vector3(NAN, 0.0, 0.0)
