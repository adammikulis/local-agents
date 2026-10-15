class_name LAEcologySpawner
extends RefCounted


const NestScene: PackedScene = preload("res://addons/local_agents/sim/actors/Nest.tscn")

const HERD_CLUSTER_SIZE: int = 18        # target members per founder cluster (fewer, bigger bands → fewer leaders)
const HERD_CLUSTER_SPREAD: float = 8.0   # tangent-plane radius (metres) members scatter around a founder —
const FOUNDER_ELDER_AGE_MULT: float = 1.6   # founder age = maturity_age × this (mature; clearly out-ranks the age-0 cohort)

# Ambient forest siting: a cluster centre is the warmest/most-fertile of several candidate sites.
const FOREST_CLUSTER_TRIES: int = 5      # candidate sites weighed per cluster (pick the warmest/most fertile)
const FOREST_CLUSTER_SPREAD: float = 15.0 # tangent-plane radius the initial cluster scatters over (metres)
const FOREST_BIOMASS_WEIGHT: float = 12.0 # how heavily fixed biomass outweighs raw warmth when siting a grove

var _eco: LAEcologyService = null


func setup(eco: LAEcologyService) -> void:
	_eco = eco


func spawn(kind: String, world_pos: Vector3) -> Node:
	if _eco.actors_root == null:
		push_warning("LAEcologySpawner.spawn before setup()")
		return null
	var placed = _place_on_surface(world_pos)
	if placed == null:
		# surface not ready: queue for retry, return null (caller may ignore)
		_eco._pending.append({"kind": kind, "pos": world_pos, "tries": 0})
		return null
	if _eco._is_veg_kind(kind) and not _eco._can_grow_here(placed):
		return null   # too cold / snow-covered — vegetation doesn't take here (emergent treeline; no retry)
	return _eco._instance_actor(kind, placed)


func spawn_initial(counts: Dictionary) -> void:
	for kind in counts.keys():
		var kind_s: String = String(kind)
		var n: int = int(counts[kind])
		if n <= 0:
			continue
		var cfg: Dictionary = _eco._species_config(kind_s)
		var cluster_size: int = HERD_CLUSTER_SIZE if bool(cfg.get("herd", false)) else int(cfg.get("found_cluster_size", 0))
		if cluster_size > 0:
			_spawn_clustered_founders(kind_s, n, cluster_size)
		else:
			for i in n:
				_spawn_scattered_one(kind_s)


# One individual at an independent random surface point. Non-vegetation founders get a random age.
func _spawn_scattered_one(kind: String) -> void:
	var p: Vector3 = _random_spawn_point()
	var placed = _place_on_surface(p)
	if placed == null:
		_eco._pending.append({"kind": kind, "pos": p, "tries": 0, "family_id": -1})
	elif _eco._is_veg_kind(kind) and not _eco._can_grow_here(placed):
		pass   # too cold / snow-covered — skip this vegetation placement (emergent treeline)
	else:
		var node = _eco._instance_actor(kind, placed)
		if node != null and not _eco._is_veg_kind(kind):
			_seed_founder_age(node)   # stagger scattered founders' ages too (no synchronized age-out)


func _spawn_clustered_founders(kind: String, n: int, cluster_size: int) -> void:
	var clusters: int = maxi(1, int(round(float(n) / float(maxi(cluster_size, 1)))))
	var base: int = n / clusters
	var extra: int = n % clusters               # spread the remainder one-per-cluster so totals match exactly
	for ci in range(clusters):
		var members: int = base + (1 if ci < extra else 0)
		if members <= 0:
			continue
		var founder_raw: Vector3 = _random_spawn_point()   # cluster centre (raw sphere point; projected below)
		var fam: int = _eco.kinship().new_family()
		for mi in range(members):
			var raw: Vector3 = founder_raw
			if mi > 0:
				raw = _tangent_offset_raw(founder_raw, LASimRng.for_domain("life").randf_range(-HERD_CLUSTER_SPREAD, HERD_CLUSTER_SPREAD), LASimRng.for_domain("life").randf_range(-HERD_CLUSTER_SPREAD, HERD_CLUSTER_SPREAD))
			var placed = _place_on_surface(raw)
			if placed == null:
				_eco._pending.append({"kind": kind, "pos": raw, "tries": 0, "family_id": fam, "elder": mi == 0})
			else:
				var node = _eco._instance_actor(kind, placed, null, fam)
				if mi == 0:
					_seed_elder(node)   # the founder at the cluster centre is the family elder → its band's stable leader
				else:
					_seed_founder_age(node)   # stagger the herd's ages so the cohort doesn't age out all at once


# Age a founder into its family elder, so it out-ranks the age-0 cohort.
func _seed_elder(node) -> void:
	if node != null and is_instance_valid(node) and node is Node3D:
		node.age = float(node.maturity_age) * FOUNDER_ELDER_AGE_MULT


func _seed_founder_age(node) -> void:
	if node != null and is_instance_valid(node) and node is Node3D:
		var span: float = maxf(float(node.max_age) * 0.6, float(node.maturity_age))
		node.age = LASimRng.for_domain("life").randf_range(0.0, span)


# Metres above the sea shell a direction's surface must clear to count as DRY LAND (not tidal shallows).
const LAND_MARGIN: float = 2.0
# Directions tried before giving up on dry land.
const LAND_TRIES: int = 32


## A raw point over ground the FIELD HOLDS, dry land where the box has any. NAN when none of the tries
## lands in a cell: nothing is placed where no matter is being simulated.
func _random_spawn_point() -> Vector3:
	var center: Vector3 = _eco.terrain.planet_center()
	var above: float = _eco.terrain.planet_radius() + 1.0
	var sea_r: float = _eco.terrain.sea_radius() if _eco.terrain.has_method("sea_radius") else 0.0
	# Drawn up front: the draw count must not depend on what the terrain answers.
	var dirs: Array[Vector3] = []
	for i in range(LAND_TRIES):
		dirs.append(random_field_dir())
	var held: Vector3 = Vector3.ZERO
	for d in dirs:
		var sr: float = _surface_radius(d)
		if is_nan(sr) or not _eco.holds(_surface_point(d)):
			continue
		held = d if held == Vector3.ZERO else held
		if sr >= sea_r + LAND_MARGIN:
			return center + d * above                  # dry land the field steps
	return center + held * above if held != Vector3.ZERO else Vector3(NAN, NAN, NAN)


func _surface_radius(dir: Vector3) -> float:
	return _eco.terrain.surface_radius(dir)


func _surface_point(dir: Vector3) -> Vector3:
	var r: float = _surface_radius(dir)
	if is_nan(r):
		return Vector3(NAN, NAN, NAN)
	return _eco.terrain.planet_center() + dir.normalized() * r


# A uniform-ish random unit direction on the sphere. Static so the aquatic sampler can reuse it.
static func _random_sphere_dir() -> Vector3:
	var v: Vector3 = LASimRng.for_domain("life").rand_dir()
	while v.length() < 0.05:
		v = LASimRng.for_domain("life").rand_dir()
	return v.normalized()


## A world direction into the region the field actually steps: the whole sphere when the field spans the
## body, the box's own footprint when it does not. Nothing lives where no matter is being simulated.
func random_field_dir() -> Vector3:
	var m = _eco._material
	var g = m._grid if m != null else null
	if g == null or g.cell_size <= 0.0 or g.nx <= 0:
		return _random_sphere_dir()
	var span: Vector3 = Vector3(g.nx, g.ny, g.nz) * g.cell_size
	if span.x >= 2.0 * _eco.terrain.planet_radius():
		return _random_sphere_dir()
	var rng = LASimRng.for_domain("life")
	var p: Vector3 = g.origin + Vector3(rng.randf() * span.x, rng.randf() * span.y, rng.randf() * span.z)
	# THE GRID IS LAID IN THE BODY'S FRAME; everything else here speaks world. This is the one crossing.
	var d: Vector3 = m.field_to_point(p) - _eco.terrain.planet_center()
	return d.normalized() if d.length() > 0.001 else _random_sphere_dir()


# The un-projected tangent-plane displacement of `anchor` by (u, v) metres.
func _tangent_offset_raw(anchor: Vector3, u: float, v: float) -> Vector3:
	var pc: Vector3 = _eco.terrain.planet_center()
	var up: Vector3 = _eco.terrain.up_at(anchor)
	if up.length() < 0.001:
		up = (anchor - pc).normalized()
	up = up.normalized()
	var ref: Vector3 = Vector3.RIGHT
	if absf(up.dot(ref)) > 0.99:
		ref = Vector3.FORWARD
	var t1: Vector3 = ref.cross(up).normalized()
	var t2: Vector3 = up.cross(t1).normalized()
	return anchor + t1 * u + t2 * v


# Project a world point radially onto the planet surface. Null when no surface resolves along it, or
# when the field does not step the cell it lands in: nothing stands where no matter is simulated.
func _place_on_surface(world_pos: Vector3):
	if _eco.terrain == null:
		return null
	var d: Vector3 = world_pos - _eco.terrain.planet_center()
	if is_nan(d.x) or d.length() < 0.001:
		return null
	var p: Vector3 = _surface_point(d.normalized())
	if is_nan(p.x) or not _eco.holds(p):
		return null
	return p


func populate_environment(forest_clusters: int) -> void:
	for c in forest_clusters:
		var center: Vector3 = _best_forest_center(FOREST_CLUSTER_TRIES)
		if is_nan(center.x):
			continue
		var trees: int = LASimRng.for_domain("life").randi_range(11, 20)
		for t in trees:
			# Scatter the cluster in the centre's tangent plane, then re-project to the sphere.
			spawn("tree", _tangent_offset_raw(center, LASimRng.for_domain("life").randf_range(-FOREST_CLUSTER_SPREAD, FOREST_CLUSTER_SPREAD), LASimRng.for_domain("life").randf_range(-FOREST_CLUSTER_SPREAD, FOREST_CLUSTER_SPREAD)))


# The most forest-suitable of `tries` random surface points. NAN-x when none qualifies.
func _best_forest_center(tries: int) -> Vector3:
	var best: Vector3 = Vector3(NAN, 0.0, 0.0)
	var best_score: float = -INF
	for i in range(tries):
		var placed = _place_on_surface(_random_spawn_point())
		if placed == null or not _eco._can_grow_here(placed, true):
			continue
		var score: float = _forest_suitability(placed)
		if score > best_score:
			best_score = score
			best = placed
	return best


# Forest suitability: fixed biomass (weighted) plus warmth above the germination threshold.
func _forest_suitability(pos: Vector3) -> float:
	var warmth: float = 0.0
	if _eco._material != null and _eco._material.has_method("temp_at"):
		warmth = _eco._material.temp_at(pos) - LAEcologyService.TREELINE_ISOTHERM_C
	return _eco._biomass_at(pos) * FOREST_BIOMASS_WEIGHT + warmth


# Place a shelter at `site`. Terrain-snapped on ground/water; kept at the caller's Y for tree roosts.
func spawn_nest(site: Vector3, nest_species: String, owner_family: int, in_tree: bool):
	if _eco.actors_root == null:
		return null
	var nest: LANest = NestScene.instantiate() as LANest
	_eco.actors_root.add_child(nest)
	nest.global_position = site
	if nest.has_method("setup"):
		nest.setup(_eco.terrain, nest_species, owner_family, in_tree)
	return nest
