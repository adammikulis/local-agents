class_name LAEcologySpawner
extends RefCounted

## Spawn / population placement for the living world — every way an actor gets ONTO the planet surface:
## the single-actor spawn, the initial population seeding (with herd founder-clustering that gives each
## band a shared family_id + an elder so leadership finds real followers), ambient rock + clustered
## forest scatter, nest placement, and the sphere-surface math (random points, tangent-plane offsets,
## radial surface projection) they all share.
##
## Owned by LAEcologyService, which keeps thin forwarders for its public API (spawn / spawn_initial /
## populate_environment / spawn_nest) and reaches back here for the placement helpers its per-tick
## breeding/seeding uses. This module reaches back into the service for the shared state that stays on
## the hub — terrain, actors_root, the material field, the pending-spawn queue, the actor instancer,
## the germination gate, species configs, biomass reads and the kinship graph — so there is exactly one
## owner of each. Explicit types only (project rule: no ':=').

const NestScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Nest.gd")

# Founder clustering — a HERDING species starts as a few tight bands, not a planet-wide smear, so local
# same-species density is high enough that leadership finds followers and durable kin herds form. One
# founder cluster per ~this many members (at least one); members scatter around the founder within a
# tangent-plane spread and share ONE family_id (the permanent kin bond). Solitary species keep scatter.
const HERD_CLUSTER_SIZE: int = 18        # target members per founder cluster (fewer, bigger bands → fewer leaders)
const HERD_CLUSTER_SPREAD: float = 8.0   # tangent-plane radius (metres) members scatter around a founder —
                                         # kept inside a ground species' leadership radius (flock_radius×1.5)
                                         # so cluster-mates fall within one leader's neighbourhood from frame 0
# The founding elder of a cluster gets a head-start age so it is unambiguously the highest-ranked member
# of its family and its cohort follows IT from the very first election — one stable leader per band instead
# of a tie-break lottery among age-0 equals. Emergent, not identity: the founder is simply the eldest.
const FOUNDER_ELDER_AGE_MULT: float = 1.6   # founder age = maturity_age × this (mature; clearly out-ranks the age-0 cohort)

# Ambient forest siting: each cluster's centre is chosen as the WARMEST / most-fertile of several
# candidate sites (the same climate the treeline reads), so groves start on the good continents.
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
		# Cluster size: a HERD species founds as big bands (HERD_CLUSTER_SIZE); a SOLITARY-but-social species
		# (a fox family group) can set found_cluster_size to found as a few SMALL family clusters instead of a
		# planet-wide smear — otherwise a handful of scattered predators never fall within one mate-seek radius
		# of each other, so they can never pair, never breed, and their age-0 founder cohort ages out to
		# extinction. A cluster of a few kin means mates are in range and natal philopatry keeps a lineage going.
		var cluster_size: int = HERD_CLUSTER_SIZE if bool(cfg.get("herd", false)) else int(cfg.get("found_cluster_size", 0))
		if cluster_size > 0:
			_spawn_clustered_founders(kind_s, n, cluster_size)
		else:
			for i in n:
				_spawn_scattered_one(kind_s)


# Place ONE individual at an independent random surface point (queue if the patch isn't meshed yet, skip
# vegetation that can't germinate here). The pre-clustering behaviour, kept for truly solitary / non-social kinds.
# Non-vegetation founders get a random age (a natural age structure) so a scattered cohort never ages out all at once.
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


# Seed a social species as K founder clusters (K scales with the count / cluster_size — a big band for a herd,
# a small family group for a solitary-but-social predator). Each cluster gets a fresh family_id and scatters its
# members around one founder site in the founder's tangent plane, so kin are spatially local from frame 0 —
# leadership then elects one leader per band with real followers, AND mates fall within one mate-seek radius so
# the group can actually reproduce. Total count is preserved. The founder sits at the cluster centre, within
# every cohort member's leadership radius, and is aged into the family elder (its band's stable leader).
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
				raw = _tangent_offset_raw(founder_raw, LASimRng.shared().randf_range(-HERD_CLUSTER_SPREAD, HERD_CLUSTER_SPREAD), LASimRng.shared().randf_range(-HERD_CLUSTER_SPREAD, HERD_CLUSTER_SPREAD))
			var placed = _place_on_surface(raw)
			if placed == null:
				_eco._pending.append({"kind": kind, "pos": raw, "tries": 0, "family_id": fam, "elder": mi == 0})
			else:
				var node = _eco._instance_actor(kind, placed, null, fam)
				if mi == 0:
					_seed_elder(node)   # the founder at the cluster centre is the family elder → its band's stable leader
				else:
					_seed_founder_age(node)   # stagger the herd's ages so the cohort doesn't age out all at once


# Age a founder into its family elder (a head-start age so it out-ranks the age-0 cohort). Shared by the
# founder seeding here and by the pending-spawn retry on the service when a founder site meshes late.
func _seed_elder(node) -> void:
	if node != null and is_instance_valid(node) and node is Node3D:
		node.age = float(node.maturity_age) * FOUNDER_ELDER_AGE_MULT


# Give a non-elder founder a RANDOM age spread across its lifespan, so the founding herd has a natural age
# structure (juveniles + adults + elders) instead of one age-0 cohort that matures, breeds, and then ages out
# ALL AT ONCE — the synchronized founder die-off that left no younger generation behind and collapsed the herd
# to extinction. A staggered age pyramid means deaths trickle out over time and there is always a next generation.
func _seed_founder_age(node) -> void:
	if node != null and is_instance_valid(node) and node is Node3D:
		var span: float = maxf(float(node.max_age) * 0.6, float(node.maturity_age))
		node.age = LASimRng.shared().randf_range(0.0, span)


# Metres above the sea shell a direction's surface must clear to count as DRY LAND (not tidal shallows).
const LAND_MARGIN: float = 2.0
# How many random directions to try before giving up on finding dry land (the planet is ~70% ocean now, so a
# handful of tries almost always lands one; the loop is cheap — a radial raycast against the low-LOD sphere).
const LAND_TRIES: int = 32


func _random_spawn_point() -> Vector3:
	# LAND-biased: the planet is ocean-DOMINANT now (~72% sea), so a blind random direction would drop most
	# land actors (herd founders, rocks, forests) onto the SEABED, underwater. Rejection-sample directions and
	# take the first whose surface clears the sea shell (dry land); keep the highest sampled direction as a
	# fallback so we still return the most-land-like point if no clearly-dry site was meshed yet. The returned
	# raw point is re-projected to the meshed ground by _place_on_surface(); an unmeshed patch queues + retries.
	var center: Vector3 = _eco.terrain.planet_center()
	var above: float = _eco.terrain.planet_radius() + 1.0
	var sea_r: float = _eco.terrain.sea_radius() if _eco.terrain.has_method("sea_radius") else 0.0
	if sea_r <= 0.0 or not _eco.terrain.has_method("surface_radius"):
		return center + _random_sphere_dir() * above
	var best_dir: Vector3 = Vector3.ZERO
	var best_r: float = -INF
	for i in range(LAND_TRIES):
		var d: Vector3 = _random_sphere_dir()
		var sr: float = _eco.terrain.surface_radius(d)
		if is_nan(sr):
			continue                                   # unmeshed patch — skip, keep trying
		if sr > best_r:
			best_r = sr
			best_dir = d
		if sr >= sea_r + LAND_MARGIN:
			return center + d * above                  # dry land found
	if best_dir == Vector3.ZERO:
		best_dir = _random_sphere_dir()                # nothing meshed yet — hand back any dir (spawn will queue)
	return center + best_dir * above


# A uniform-ish random unit direction on the sphere (reject the degenerate near-zero vector). Static +
# stateless so the service's aquatic sampler can reuse it without a spawner instance.
static func _random_sphere_dir() -> Vector3:
	var v: Vector3 = LASimRng.shared().rand_dir()
	while v.length() < 0.05:
		v = LASimRng.shared().rand_dir()
	return v.normalized()


# Offset a surface anchor by (u, v) metres within its LOCAL TANGENT PLANE, then re-project the
# displaced point back onto the sphere surface. This keeps clustered spawns (forests, nests, seeds)
# hugging the ground instead of drifting radially in/out as a world-axis XZ offset would near the
# "sides" of the globe. Returns a surface point (NAN-x if that patch isn't meshed).
func _tangent_offset_point(anchor: Vector3, u: float, v: float) -> Vector3:
	var pc: Vector3 = _eco.terrain.planet_center()
	return _eco.terrain.surface_point((_tangent_offset_raw(anchor, u, v) - pc).normalized())


# The RAW (un-projected) tangent-plane displacement of `anchor` by (u, v) metres. Kept separate from
# _tangent_offset_point so callers that project themselves (or queue an unmeshed point for retry) can
# reuse the offset math without forcing a surface lookup that fails on not-yet-meshed ground.
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


# Resolve a surface position for a world point by projecting it radially onto the meshed sphere surface
# (via its direction from the planet centre). Returns a positioned Vector3, or null if the terrain isn't
# meshed there yet.
func _place_on_surface(world_pos: Vector3):
	if _eco.terrain == null:
		return null
	var d: Vector3 = world_pos - _eco.terrain.planet_center()
	if is_nan(d.x) or d.length() < 0.001:
		return null
	var p: Vector3 = _eco.terrain.surface_point(d.normalized())
	if is_nan(p.x):
		return null
	return p


# Scatter ambient rocks and SEED clustered forests across the world (independent of meteors). Each forest
# cluster's centre is chosen as the WARMEST / most-fertile of several candidate sites, so groves start on
# the good continents rather than the frozen poles. From these seeds the groves DENSIFY over the run
# wherever photosynthesis has built biomass (see LAEcologyService._tick_tree_seeding).
func populate_environment(rock_count: int, forest_clusters: int) -> void:
	for i in rock_count:
		spawn("rock", _random_spawn_point())
	for c in forest_clusters:
		var center: Vector3 = _best_forest_center(FOREST_CLUSTER_TRIES)
		if is_nan(center.x):
			continue
		var trees: int = LASimRng.shared().randi_range(11, 20)
		for t in trees:
			# Scatter the cluster in the centre's tangent plane, then re-project to the sphere.
			spawn("tree", _tangent_offset_point(center, LASimRng.shared().randf_range(-FOREST_CLUSTER_SPREAD, FOREST_CLUSTER_SPREAD), LASimRng.shared().randf_range(-FOREST_CLUSTER_SPREAD, FOREST_CLUSTER_SPREAD)))


# Pick the most forest-suitable of `tries` random surface points: highest biomass, warmest, snow-free. At
# spawn biomass is ~0 everywhere so warmth (the photosynthesis driver) decides — clusters land on the warm
# continents; later succession then reads the biomass those forests build. NAN-x if no meshed site found.
func _best_forest_center(tries: int) -> Vector3:
	var best: Vector3 = Vector3(NAN, 0.0, 0.0)
	var best_score: float = -INF
	for i in range(tries):
		var placed = _place_on_surface(_random_spawn_point())
		if placed == null or not _eco._can_grow_here(placed):
			continue
		var score: float = _forest_suitability(placed)
		if score > best_score:
			best_score = score
			best = placed
	return best


# Forest suitability of a surface point: biomass the photosynthesis chemistry has fixed there (weighted
# high) plus the local warmth above the germination threshold (the biomass driver, so it ranks sites
# before any biomass exists). Higher = better forest ground; drives initial siting.
func _forest_suitability(pos: Vector3) -> float:
	var warmth: float = 0.0
	if _eco._material != null and _eco._material.has_method("temp_at"):
		warmth = _eco._material.temp_at(pos) - LAEcologyService.GROW_MIN_TEMP
	return _eco._biomass_at(pos) * FOREST_BIOMASS_WEIGHT + warmth


# Place a shelter (LANest) at `site` for a nesting creature. Terrain-snapped for ground/water shelters;
# kept at the caller's Y for tree roosts (in_tree=true).
func spawn_nest(site: Vector3, nest_species: String, owner_family: int, in_tree: bool):
	if _eco.actors_root == null:
		return null
	var nest = NestScript.new()
	_eco.actors_root.add_child(nest)
	nest.global_position = site
	if nest.has_method("setup"):
		nest.setup(_eco.terrain, nest_species, owner_family, in_tree)
	return nest
