class_name LACreatureNesting
extends RefCounted

## Home-site behaviour for LACreature, factored out of the main brain. General across species:
## flyers roost/breed in the treetops, ground species shelter in a burrow near where they stand.
## All functions are static and take the creature `c`, reading its fields dynamically so this stays
## dependency-free of the LACreature type (no cyclic class reference). These helpers only DECIDE and
## STEER — they never spawn the Nest actor or mutate `c`; the caller owns `c.nest_pos`/`c.has_nest`
## and the actual spawn. (Explicit types only — project rule: no ':=' inferred typing.)

# How far above a tree's own position a flyer roosts (treetop clearance, metres).
const TREETOP_RISE: float = 5.0
# Extra lift for a ground burrow's stored Y so it sits just proud of the surface.
const GROUND_RISE: float = 0.5
# Horizontal scatter for a ground shelter site (metres).
const GROUND_SCATTER: float = 4.0


## True when the creature should head home NOW. It must nest at all, AND either it is its OFF-hours
## (diurnal animals rest at night, nocturnal ones by day — from the `nocturnal` flag + the shared
## clock, no per-species schedule) so it sleeps at the shelter, OR it is a mature, well-fed adult
## ready to breed at the nest.
static func should_seek_nest(c) -> bool:
	if not c.nests:
		return false
	var night: bool = c._ecology != null and c._ecology.has_method("is_night") and c._ecology.is_night()
	var resting: bool = night != bool(c.nocturnal)
	if resting:
		return true
	var breeding_ready: bool = c.age >= c.maturity_age and c.energy > c.max_energy * 0.6
	return breeding_ready


## Pick a home world position. Flyers roost above the nearest visible/near TREE (elevated to roughly
## treetop); ground species shelter in a sheltered spot just off `pos`. Returns a Vector3 with a
## sensible Y. Falls back to `pos` when no tree / invalid terrain.
static func choose_site(c, pos: Vector3) -> Vector3:
	var habitat: String = String(c.nest_habitat)
	if habitat == "":
		habitat = "tree" if c.can_fly else "ground"
	# Aquatic nesters (reed/bank/submerged nests) home to the nearest pooled water.
	if habitat == "water":
		var w: Vector3 = _nearest_water_site(c, pos)
		if not is_inf(w.x):
			return w
		# no water within reach: fall through to a ground burrow near the shore
	if habitat == "tree":
		var tree: Node3D = _nearest_tree(c, pos)
		if tree != null:
			var tp: Vector3 = tree.global_position
			var surf: float = c.terrain.surface_height(tp.x, tp.z)
			var base_y: float = tp.y
			if not is_nan(surf):
				base_y = maxf(tp.y, surf)
			return Vector3(tp.x, base_y + TREETOP_RISE, tp.z)
		return pos
	# Ground/burrow species: a small sheltered offset from where it stands, pinned to the surface.
	var ox: float = (randf() * 2.0 - 1.0) * GROUND_SCATTER
	var oz: float = (randf() * 2.0 - 1.0) * GROUND_SCATTER
	var site: Vector3 = Vector3(pos.x + ox, pos.y, pos.z + oz)
	var gs: float = c.terrain.surface_height(site.x, site.z)
	if is_nan(gs):
		return pos
	site.y = gs + GROUND_RISE
	return site


## Nearest pooled-water site (for aquatic nesters), probed in rings via the shared material field.
static func _nearest_water_site(c, pos: Vector3) -> Vector3:
	var water = c._material
	if water == null or not water.has_method("is_water_at"):
		return Vector3(INF, INF, INF)
	if water.is_water_at(pos.x, pos.z):
		return pos
	var radii: Array = [c.sense_radius, c.sense_radius * 2.0, c.sense_radius * 3.5]
	var dirs: int = 12
	for r in radii:
		for k in range(dirs):
			var ang: float = TAU * float(k) / float(dirs)
			var px: float = pos.x + cos(ang) * float(r)
			var pz: float = pos.z + sin(ang) * float(r)
			if water.is_water_at(px, pz):
				var y: float = c.terrain.surface_height(px, pz)
				if is_nan(y):
					y = pos.y
				return Vector3(px, y, pz)
	return Vector3(INF, INF, INF)


## Flat-or-full unit heading from `pos` toward `c.nest_pos`. Ground creatures ignore Y (walk there);
## flyers keep the full vector so they climb/descend to the roost. ZERO if there is no nest or the
## creature is essentially already there.
static func steer_to_nest(c, pos: Vector3) -> Vector3:
	if not c.has_nest or is_inf(c.nest_pos.x):
		return Vector3.ZERO
	var to: Vector3 = c.nest_pos - pos
	if not c.can_fly:
		to.y = 0.0
	if to.length() < 0.5:
		return Vector3.ZERO
	return to.normalized()


## Within `radius` (measured in the XZ plane) of the creature's nest. False if it has no nest.
static func at_nest(c, pos: Vector3, radius: float = 2.5) -> bool:
	if not c.has_nest or is_inf(c.nest_pos.x):
		return false
	var dx: float = c.nest_pos.x - pos.x
	var dz: float = c.nest_pos.z - pos.z
	return (dx * dx + dz * dz) <= radius * radius


## Nearest tree the creature can see (or, failing sight, that is simply within sense range) — the
## anchor a flyer roosts above.
static func _nearest_tree(c, pos: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d: float = c.sense_radius * c._sense_mult
	for t in c.get_tree().get_nodes_in_group("tree"):
		if not is_instance_valid(t) or not (t is Node3D):
			continue
		var t3: Node3D = t as Node3D
		var d: float = pos.distance_to(t3.global_position)
		if d > best_d:
			continue
		if not LAVision.can_see(c, t3.global_position):
			continue
		best_d = d
		best = t3
	return best
