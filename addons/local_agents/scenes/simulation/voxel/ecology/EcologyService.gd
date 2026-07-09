class_name LAEcologyService
extends Node

# Drives the living world: spawning, predator-prey population dynamics, breeding
# with population caps, herd cohesion (delegated to creatures), and plant seeding.
# Every actor is placed on the terrain surface via LAVoxelTerrainService.

const CreatureScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Creature.gd")
const PlantScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Plant.gd")
const RockScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Rock.gd")
const TreeScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Tree.gd")
const FishScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Fish.gd")
const TrackSystemScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/TrackSystem.gd")
const NestScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Nest.gd")

const KINDS: Array = ["plant", "rabbit", "fox", "bird", "villager", "fish", "rock", "tree"]

# Aquatic sampling budget: tries per placement to land inside a species' salinity/depth band (radial).
const AQUATIC_SAMPLE_TRIES: int = 60
# A LIVING sea: scale every aquatic species' starting count AND its population cap by this factor so the
# ocean/lakes teem instead of trickling. Data files stay the single source of the per-species ratios; this
# is the one owned dial that makes the water busy without editing eight species files.
const AQUATIC_STOCK_MULT: float = 2.6

var terrain = null                       # LAVoxelTerrainService
var actors_root: Node3D = null
var _tracks = null                       # LATrackSystem (observer; footprints)
var _material = null                      # LAMaterialField — the ONE substrate (water/heat/materials)
var _cognition_sched = null              # LACognitionScheduler (shared slow-brain budget/queue)

# Shared day/night clock (0=midnight .. 0.5=noon), set by VoxelWorld each frame. Creatures
# read is_night() so nocturnal species behave differently after dark — emergent, not scripted.
var time_of_day: float = 0.3


func set_time_of_day(t: float) -> void:
	time_of_day = t


func is_night() -> bool:
	# Sun is below the horizon between dusk (~0.78) and dawn (~0.22).
	return time_of_day < 0.22 or time_of_day > 0.78

# pending spawns whose surface wasn't ready yet: [{kind, pos, tries}]
var _pending: Array = []
var _breed_timer: float = 0.0
var _seed_timer: float = 0.0
var _fish_timer: float = 0.0
var _tree_timer: float = 0.0             # forest succession: groves densify on biomass-rich ground
var _aquatic_kinds_cache: Array = []     # aquatic species ids (config aquatic:true), indexed once
var _aquatic_indexed: bool = false
# Permanent kinship graph backing every creature's family_id. A family is a connected component; family_id is
# its stable label. Founder clusters allocate a fresh label (LAKinshipGraph.new_family) and offspring inherit
# their parent's component at birth — bonds are recorded once, never rewritten. Updated only on the
# founding/birth/death events (never per frame); kin recognition reads the cheap family_id, not the graph.
var _kinship: LAKinshipGraph = LAKinshipGraph.new()


# The permanent kinship graph (owned here; the field/world hubs stay extract-only).
func kinship() -> LAKinshipGraph:
	return _kinship

# --- Seismic / shock stimulus (emergent camera shake) ------------------------
# Ground disturbances now inject into the field's PROPAGATING shock wave (LAMaterialShock3D); the camera
# reads seismic_energy_at() (→ field.shock_at) and shakes. No local ring — the wave carries it (see below).


# --- species / plant configs ------------------------------------------------
func _species_config(kind: String) -> Dictionary:
	# Species stats live in per-type DATA files under data/species/<class>/<kind>.json, kept OUT of
	# this business logic so a creature can be retuned by editing one small file (see LASpeciesLibrary).
	return LASpeciesLibrary.load_config(kind)


# Every species whose data file is flagged `aquatic: true` (fish variants, turtle, crab, whale, …).
# Indexed once from the species library; drives all aquatic stocking generically — no hardcoded list.
func _aquatic_kinds() -> Array:
	if _aquatic_indexed:
		return _aquatic_kinds_cache
	_aquatic_indexed = true
	_aquatic_kinds_cache = []
	for kind in LASpeciesLibrary.known_kinds():
		var cfg: Dictionary = LASpeciesLibrary.load_config(String(kind))
		if bool(cfg.get("aquatic", false)):
			_aquatic_kinds_cache.append(String(kind))
	return _aquatic_kinds_cache


func _plant_config() -> Dictionary:
	return {
		"species": "plant", "color": Color(0.30, 0.66, 0.24),
		"grow_time": 8.0, "max_scale": 2.0, "seed_period": 9.0,
		"edible": true, "pop_cap": 120,
	}


func setup(_terrain, _actors_root: Node3D) -> void:
	terrain = _terrain
	actors_root = _actors_root
	# Scent/waste is now an emergent field channel (LAMaterialScent3D in MaterialField3D), not an observer.
	_tracks = TrackSystemScript.new()
	_tracks.name = "TrackSystem"
	add_child(_tracks)
	_tracks.setup(terrain)
	# Shared System-2 slow brain (FunctionGemma) with a global call budget; creatures escalate to
	# it rarely and asynchronously. Loaded by path + guarded so the sim still runs on pure fast
	# heuristics + social learning if the scheduler script or model is unavailable.
	var sched_script: GDScript = load("res://addons/local_agents/scenes/simulation/voxel/cognition/CognitionScheduler.gd")
	if sched_script != null:
		_cognition_sched = sched_script.new()
		_cognition_sched.name = "CognitionScheduler"
		add_child(_cognition_sched)
		if _cognition_sched.has_method("setup"):
			# Point the slow brain at a running FunctionGemma llama-server if one is configured
			# (env FUNCTIONGEMMA_URL); otherwise it uses the built-in heuristic teacher fallback.
			var opts: Dictionary = {}
			var url: String = OS.get_environment("FUNCTIONGEMMA_URL")
			if url != "":
				opts["server_url"] = url
			_cognition_sched.setup(opts)


# The ONE substrate: water (creatures drink, fish live in it), heat/temperature (fire + comfort),
# and every material. Disasters inject heat/material; everything else reads it.
func set_material_field(m) -> void:
	_material = m
	# The field owns combustion (no separate fire system) and needs to reach back for
	# topple/reseed/scare when it consumes a burning actor.
	if _material != null and _material.has_method("set_ecology"):
		_material.set_ecology(self)


func material_field():
	return _material


# Back-compat accessor: fire lives in the material field now (combustion folded in).
func fire_system():
	return _material


# Broadcast a GROUND-DISTURBANCE stimulus (meteor blast, earthquake, later saturated slope). It just
# tells the material field the earth was shaken here — loose/steep ground then slumps toward its angle
# of repose under GRAVITY, in the field's own granular step. No landslide "system"; it's material
# physics. One channel every disaster reuses.
func disturb_ground(world_pos: Vector3, radius: float, strength: float) -> void:
	if _material != null and _material.has_method("disturb_terrain"):
		_material.disturb_terrain(world_pos, radius, strength)
	# EVERY ground disturbance is also FELT as a seismic pulse — the camera shake emerges from this, so
	# no caller needs its own shake call. A wider disturbance moves more ground, so it hits harder.
	broadcast_seismic(world_pos, strength * clampf(radius / 12.0, 0.3, 4.0))


# The seismic/shock stimulus is now a REAL PROPAGATING FIELD (LAMaterialShock3D in MaterialField3D), not
# a point ring: every ground-disturbing event injects a shock wave that radiates outward + is muffled by
# terrain, so a blast behind a ridge is felt less for free. The ecology just mediates the actor→field call
# (this is the ONE stimulus every impact/tremor feeds); the camera + energy graph read it back below.
func broadcast_seismic(world_pos: Vector3, magnitude: float) -> void:
	if magnitude <= 0.0:
		return
	if _material != null and _material.has_method("emit_shock"):
		_material.emit_shock(world_pos, magnitude)


# Shock energy felt at world_pos — the propagated field value (proximity + terrain muffling emerge from
# the wave). The camera rig queries this and shakes in proportion.
func seismic_energy_at(world_pos: Vector3) -> float:
	return _material.shock_at(world_pos) if _material != null and _material.has_method("shock_at") else 0.0


# Scene-wide shock intensity (peak) for the energy graph / streamer.
func total_seismic_energy() -> float:
	return _material.shock_peak() if _material != null and _material.has_method("shock_peak") else 0.0


func cognition_scheduler():
	return _cognition_sched


# A hot event "starts a fire" only by depositing heat — vegetation there ignites on the next
# combustion scan because its cell crossed the ignition temperature. Pure emergence, no fire code.
func ignite_area(world_pos: Vector3, radius: float) -> void:
	if _material != null and _material.has_method("add_heat"):
		_material.add_heat(world_pos, 900.0, radius)   # ~3x wood's 300°C ignition temp


# Emergent growth CONDITION (not a hardcoded elevation): a seed only takes where the ground is warm enough
# and not under snow. Because the temperature field cools with altitude (LAPSE) and snow forms on the cold
# summits, this makes the treeline + the bare snow cap EMERGE from the climate — a warm coast forests over,
# frozen peaks stay bare, and the line MOVES if the climate warms/cools. GROW_MIN_TEMP is the germination
# threshold (a property of vegetation, tunable), read against the field — never an elevation number.
const GROW_MIN_TEMP: float = 7.5          # °C below which the ground is too cold for a seed to germinate
const GROW_SNOW_MAX: float = 0.02         # snowpack depth above which the ground is snow-covered (no germination)


# The SKY-EXPOSED open cell one voxel ABOVE a ground point (offset outward along the radial). Biomass,
# snow and near-surface temperature live in that open surface cell, NOT in the solid cell a base-anchored
# actor's exact position maps to — so every climate read below samples here to get the real values.
const SURFACE_PROBE_UP: float = 6.0     # a little over one 5-unit field cell, into the open surface layer
func _air_point(pos: Vector3) -> Vector3:
	if terrain != null and terrain.has_method("up_at"):
		var u: Vector3 = terrain.up_at(pos)
		if u.length() > 0.0001:
			return pos + u.normalized() * SURFACE_PROBE_UP
	return pos + Vector3.UP * SURFACE_PROBE_UP


# Can vegetation take root at `placed`? Reads the field CONDITIONS (temperature + snow cover) in the TRUE
# 3D sky-exposed surface cell (three-d-always — the 2.5D x,z form returns safe defaults on a sphere and never
# gates), so the treeline is emergent: warm snow-free ground greens over, frozen/snow-capped poles stay bare
# and the line MOVES with the climate. True when there is no material field wired yet (boot spawns aren't blocked).
func _can_grow_here(placed: Vector3) -> bool:
	if _material == null:
		return true
	var air: Vector3 = _air_point(placed)
	if _material.has_method("temp_at") and _material.temp_at(air.x, air.z, air.y) < GROW_MIN_TEMP:
		return false   # too cold — above the emergent treeline
	if _material.has_method("snow_depth_at") and _material.snow_depth_at(air.x, air.z, air.y) > GROW_SNOW_MAX:
		return false   # snow-covered ground
	return true


# Radius of the SKY-EXPOSED top shell cell (r = depth-1), where photosynthesis (MaterialReactions3D R19, gated
# to the outermost open cell that faces space) deposits the biomass for a whole column. Cached from the sphere
# grid; -1 until the field is wired. Biomass is read there, per column, not at the ground.
var _shell_sample_radius: float = -1.0
func _shell_top_radius() -> float:
	if _shell_sample_radius > 0.0:
		return _shell_sample_radius
	if _material != null and _material.has_method("sphere_grid"):
		var g: RefCounted = _material.sphere_grid()
		if g != null:
			_shell_sample_radius = float(g.core_radius) + (float(g.depth) - 0.5) * float(g.cell_size)
	return _shell_sample_radius


# Living BIOMASS above a surface point — the emergent photosynthesis product for that column (warm, sunlit,
# CO₂-rich columns fix the most). Read at the sky-exposed top shell cell along the point's radial, since that
# is where R19 deposits it. Forests gate on this so groves densify under the columns the chemistry made most
# productive (sunlit continents) and stay sparse under cold/polar/night columns. 0 when no field wired yet.
func _biomass_at(pos: Vector3) -> float:
	if _material == null or not _material.has_method("biomass_at"):
		return 0.0
	var r: float = _shell_top_radius()
	if r <= 0.0:
		return _material.biomass_at(pos.x, pos.y, pos.z)
	var pc: Vector3 = terrain.planet_center()
	var dir: Vector3 = pos - pc
	if dir.length() < 0.001:
		return 0.0
	var s: Vector3 = pc + dir.normalized() * r
	return _material.biomass_at(s.x, s.y, s.z)


func spawn(kind: String, world_pos: Vector3) -> Node:
	if actors_root == null:
		push_warning("LAEcologyService.spawn before setup()")
		return null
	var placed = _place_on_surface(world_pos)
	if placed == null:
		# surface not ready: queue for retry, return null (caller may ignore)
		_pending.append({"kind": kind, "pos": world_pos, "tries": 0})
		return null
	if (kind == "tree" or kind == "plant") and not _can_grow_here(placed):
		return null   # too cold / snow-covered — vegetation doesn't take here (emergent treeline; no retry)
	return _instance_actor(kind, placed)


# Founder clustering — a HERDING species starts as a few tight bands, not a planet-wide smear, so local
# same-species density is high enough that leadership finds followers and durable kin herds form. One founder
# cluster per ~this many members (at least one); members scatter around the founder within a tangent-plane
# spread and share ONE family_id (the permanent kin bond). Solitary species keep the independent scatter.
const HERD_CLUSTER_SIZE: int = 18        # target members per founder cluster (fewer, bigger bands → fewer leaders)
const HERD_CLUSTER_SPREAD: float = 8.0   # tangent-plane radius (metres) members scatter around a founder —
                                         # kept inside a ground species' leadership radius (flock_radius×1.5)
                                         # so cluster-mates fall within one leader's neighbourhood from frame 0


func spawn_initial(counts: Dictionary) -> void:
	for kind in counts.keys():
		var kind_s: String = String(kind)
		var n: int = int(counts[kind])
		if n <= 0:
			continue
		var cfg: Dictionary = _species_config(kind_s)
		if bool(cfg.get("herd", false)):
			_spawn_herd_founders(kind_s, n)
		else:
			for i in n:
				_spawn_scattered_one(kind_s)


# Place ONE individual at an independent random surface point (queue if the patch isn't meshed yet, skip
# vegetation that can't germinate here). The pre-clustering behaviour, kept for solitary / non-herd kinds.
func _spawn_scattered_one(kind: String) -> void:
	var p: Vector3 = _random_spawn_point()
	var placed = _place_on_surface(p)
	if placed == null:
		_pending.append({"kind": kind, "pos": p, "tries": 0, "family_id": -1})
	elif (kind == "tree" or kind == "plant") and not _can_grow_here(placed):
		pass   # too cold / snow-covered — skip this vegetation placement (emergent treeline)
	else:
		_instance_actor(kind, placed)


# Seed a herding species as K founder clusters (K scales with the count). Each cluster gets a fresh family_id
# and scatters its members around one founder site in the founder's tangent plane, so kin are spatially local
# from frame 0 — leadership then elects one leader per band with real followers. Total count is preserved.
# The founding elder of a cluster: a head-start age so it is unambiguously the highest-ranked member of its
# family and its cohort follows IT from the very first election — one stable leader per band instead of a
# tie-break lottery among age-0 equals (which was the main run-to-run variance in the follower count). The
# elder sits at the cluster centre, within every cohort member's leadership radius. Emergent, not identity:
# the founder is simply the lineage's eldest; nothing is hard-coded per species.
const FOUNDER_ELDER_AGE_MULT: float = 1.6   # founder age = maturity_age × this (mature; clearly out-ranks the age-0 cohort)


func _seed_elder(node) -> void:
	if node != null and is_instance_valid(node) and node is Node3D:
		node.age = float(node.maturity_age) * FOUNDER_ELDER_AGE_MULT


func _spawn_herd_founders(kind: String, n: int) -> void:
	var clusters: int = maxi(1, int(round(float(n) / float(HERD_CLUSTER_SIZE))))
	var base: int = n / clusters
	var extra: int = n % clusters               # spread the remainder one-per-cluster so totals match exactly
	for ci in range(clusters):
		var members: int = base + (1 if ci < extra else 0)
		if members <= 0:
			continue
		var founder_raw: Vector3 = _random_spawn_point()   # cluster centre (raw sphere point; projected below)
		var fam: int = _kinship.new_family()
		for mi in range(members):
			var raw: Vector3 = founder_raw
			if mi > 0:
				raw = _tangent_offset_raw(founder_raw, randf_range(-HERD_CLUSTER_SPREAD, HERD_CLUSTER_SPREAD), randf_range(-HERD_CLUSTER_SPREAD, HERD_CLUSTER_SPREAD))
			var placed = _place_on_surface(raw)
			if placed == null:
				_pending.append({"kind": kind, "pos": raw, "tries": 0, "family_id": fam, "elder": mi == 0})
			else:
				var node = _instance_actor(kind, placed, null, fam)
				if mi == 0:
					_seed_elder(node)   # the founder at the cluster centre is the family elder → its band's stable leader


func _random_spawn_point() -> Vector3:
	# On a sphere the whole surface is fair game: pick a random unit direction from the planet centre and
	# hand back a point along it (above the surface); _place_on_surface() re-projects it down to the meshed
	# ground radially. (The planet is the sole world — the old flat XZ scatter is gone.)
	return terrain.planet_center() + _random_sphere_dir() * (terrain.planet_radius() + 1.0)


# A uniform-ish random unit direction on the sphere (reject the degenerate near-zero vector).
func _random_sphere_dir() -> Vector3:
	var v: Vector3 = Vector3(randf() * 2.0 - 1.0, randf() * 2.0 - 1.0, randf() * 2.0 - 1.0)
	while v.length() < 0.05:
		v = Vector3(randf() * 2.0 - 1.0, randf() * 2.0 - 1.0, randf() * 2.0 - 1.0)
	return v.normalized()


# Offset a surface anchor by (u, v) metres within its LOCAL TANGENT PLANE, then re-project the
# displaced point back onto the sphere surface. This keeps clustered spawns (forests, nests, seeds)
# hugging the ground instead of drifting radially in/out as a world-axis XZ offset would near the
# "sides" of the globe. Returns a surface point (NAN-x if that patch isn't meshed).
func _tangent_offset_point(anchor: Vector3, u: float, v: float) -> Vector3:
	var pc: Vector3 = terrain.planet_center()
	return terrain.surface_point((_tangent_offset_raw(anchor, u, v) - pc).normalized())


# The RAW (un-projected) tangent-plane displacement of `anchor` by (u, v) metres. Kept separate from
# _tangent_offset_point so callers that project themselves (or queue an unmeshed point for retry) can reuse
# the offset math without forcing a surface lookup that fails on not-yet-meshed ground.
func _tangent_offset_raw(anchor: Vector3, u: float, v: float) -> Vector3:
	var pc: Vector3 = terrain.planet_center()
	var up: Vector3 = terrain.up_at(anchor)
	if up.length() < 0.001:
		up = (anchor - pc).normalized()
	up = up.normalized()
	var ref: Vector3 = Vector3.RIGHT
	if absf(up.dot(ref)) > 0.99:
		ref = Vector3.FORWARD
	var t1: Vector3 = ref.cross(up).normalized()
	var t2: Vector3 = up.cross(t1).normalized()
	return anchor + t1 * u + t2 * v


# Orient a spawned static actor (tree/plant/rock) so its local +Y points along the radial up at its
# position — otherwise everything would stand parallel to world +Y and lean over as you round the
# globe. Preserves the node's current scale.
func _orient_to_surface(node: Node3D, pos: Vector3) -> void:
	if node == null:
		return
	var up: Vector3 = terrain.up_at(pos)
	if up.length() < 0.001:
		return
	up = up.normalized()
	if node.has_method("set_up"):
		node.set_up(up)
		return
	var ref: Vector3 = Vector3.RIGHT
	if absf(up.dot(ref)) > 0.99:
		ref = Vector3.FORWARD
	var right: Vector3 = ref.cross(up).normalized()
	var fwd: Vector3 = up.cross(right).normalized()
	var scl: Vector3 = node.scale
	node.global_transform = Transform3D(Basis(right, up, fwd), pos)
	node.scale = scl


# True when `placed` sits in water — inside the planet's sea shell (at or below the sea radius).
func _is_water_pos(placed: Vector3) -> bool:
	return (placed - terrain.planet_center()).length() <= terrain.sea_radius()


# Resolve a surface position for a world point by projecting it radially onto the meshed sphere surface
# (via its direction from the planet centre). Returns a positioned Vector3, or null if the terrain isn't
# meshed there yet.
func _place_on_surface(world_pos: Vector3):
	if terrain == null:
		return null
	var d: Vector3 = world_pos - terrain.planet_center()
	if is_nan(d.x) or d.length() < 0.001:
		return null
	var p: Vector3 = terrain.surface_point(d.normalized())
	if is_nan(p.x):
		return null
	return p


func _instance_actor(kind: String, placed: Vector3, genome = null, family_id: int = -1) -> Node:
	var node: Node = null
	if kind == "plant":
		var plant: PlantScript = PlantScript.new()
		actors_root.add_child(plant)
		plant.global_position = placed
		plant.setup(terrain, _plant_config())
		if plant.has_method("set_material_field"):
			plant.set_material_field(_material)          # so it can photosynthesize (fix CO₂ → O₂) into the field
		node = plant
	elif kind == "rock":
		var rock: RockScript = RockScript.new()
		actors_root.add_child(rock)
		rock.global_position = placed
		rock.setup(terrain)
		node = rock
	elif kind == "tree":
		var tree: TreeScript = TreeScript.new()
		actors_root.add_child(tree)
		tree.global_position = placed
		tree.setup(terrain, _tree_config())
		node = tree
	else:
		var cfg: Dictionary = _species_config(kind)
		if cfg.is_empty():
			push_warning("LAEcologyService: unknown kind '%s'" % kind)
			return null
		# Aquatic species (config aquatic:true) are all driven by the ONE LAFish script — a fish, turtle,
		# crab or whale differ only by config (salinity/depth band, body, speed). They exist only in water.
		if bool(cfg.get("aquatic", false)):
			if not _is_water_pos(placed):
				return null
			var fish: FishScript = FishScript.new()
			actors_root.add_child(fish)
			fish.global_position = placed
			fish.setup(terrain, _material, cfg)
			return fish
		# Founder clusters share a family_id (permanent kin bond). Only applies to the ancestral (null-genome)
		# path — a bred offspring carries its inherited family_id in the genome's base_config instead.
		if family_id >= 0 and genome == null:
			cfg["family_id"] = family_id
		var creature: CreatureScript = CreatureScript.new()
		actors_root.add_child(creature)
		creature.global_position = placed
		creature.setup(terrain, cfg, genome)          # genome (if bred) drives traits + instincts
		if creature.has_method("set_ecology"):
			creature.set_ecology(self)
		if creature.has_method("set_material_field"):
			creature.set_material_field(_material)
		if creature.has_method("set_cognition_scheduler"):
			creature.set_cognition_scheduler(_cognition_sched)
		# Back family_id with the kinship graph. Founder-cluster members (family_id >= 0) join their shared
		# family component; an offspring already carries its inherited label (registered at the breeding site).
		# On removal (death), the creature forgets itself so the graph stays bounded (event-driven, O(degree)).
		var cid: int = int(creature.get_instance_id())
		if family_id >= 0:
			_kinship.add_member(family_id, cid)
		creature.tree_exited.connect(func() -> void: _kinship.forget(cid))
		node = creature
	# Stand static vegetation/rocks up along the radial on a planet (no-op on flat terrain).
	if node != null and (kind == "plant" or kind == "tree" or kind == "rock"):
		_orient_to_surface(node as Node3D, placed)
	return node


func _tree_config() -> Dictionary:
	var pine: bool = randf() < 0.4
	return {"species": "pine" if pine else "oak"}


# Scatter ambient rocks and SEED clustered forests across the world (independent of meteors). Each forest
# cluster's centre is chosen as the WARMEST / most-fertile of several candidate sites (the same climate the
# treeline reads), so groves start on the good continents rather than the frozen poles. From these seeds the
# groves DENSIFY over the run wherever photosynthesis has built biomass (see _tick_tree_seeding).
const FOREST_CLUSTER_TRIES: int = 5      # candidate sites weighed per cluster (pick the warmest/most fertile)
const FOREST_CLUSTER_SPREAD: float = 15.0 # tangent-plane radius the initial cluster scatters over (metres)
func populate_environment(rock_count: int, forest_clusters: int) -> void:
	for i in rock_count:
		spawn("rock", _random_spawn_point())
	for c in forest_clusters:
		var center: Vector3 = _best_forest_center(FOREST_CLUSTER_TRIES)
		if is_nan(center.x):
			continue
		var trees: int = randi_range(11, 20)
		for t in trees:
			# Scatter the cluster in the centre's tangent plane, then re-project to the sphere.
			spawn("tree", _tangent_offset_point(center, randf_range(-FOREST_CLUSTER_SPREAD, FOREST_CLUSTER_SPREAD), randf_range(-FOREST_CLUSTER_SPREAD, FOREST_CLUSTER_SPREAD)))


# Pick the most forest-suitable of `tries` random surface points: highest biomass, warmest, snow-free. At
# spawn biomass is ~0 everywhere so warmth (the photosynthesis driver) decides — clusters land on the warm
# continents; later succession then reads the biomass those forests build. NAN-x if no meshed site found.
func _best_forest_center(tries: int) -> Vector3:
	var best: Vector3 = Vector3(NAN, 0.0, 0.0)
	var best_score: float = -INF
	for i in range(tries):
		var placed = _place_on_surface(_random_spawn_point())
		if placed == null or not _can_grow_here(placed):
			continue
		var score: float = _forest_suitability(placed)
		if score > best_score:
			best_score = score
			best = placed
	return best


# Forest suitability of a surface point: biomass the photosynthesis chemistry has fixed there (weighted
# high) plus the local warmth above the germination threshold (the biomass driver, so it ranks sites before
# any biomass exists). Higher = better forest ground; drives both initial siting and grove succession.
const FOREST_BIOMASS_WEIGHT: float = 12.0
func _forest_suitability(pos: Vector3) -> float:
	var warmth: float = 0.0
	if _material != null and _material.has_method("temp_at"):
		warmth = _material.temp_at(pos.x, pos.z, pos.y) - GROW_MIN_TEMP
	return _biomass_at(pos) * FOREST_BIOMASS_WEIGHT + warmth


# Deterministic point-source falloff: MAX (1.0) at the centre, 0.0 at/beyond the edge, squared
# for a sharp peak so a blast/bolt kills hard near the impact and tapers quickly toward the rim.
# No randomness — the same distance always yields the same fraction. Shared by every point blast
# (damage_sphere here, lightning's fish electrocution).
static func blast_falloff(d: float, radius: float) -> float:
	if radius <= 0.0:
		return 0.0
	var f: float = clampf(1.0 - d / radius, 0.0, 1.0)
	return f * f


# A point blast (meteor, earthquake, lightning). Deals GRADED, deterministic damage: each actor in
# range with take_damage() loses base_damage * falloff(distance) HP and dies only when its HP hits 0
# — lethal at the centre, survivable at the rim. `base_damage` defaults large so the centre still
# reproduces the old lethal-blast feel. Actors without take_damage (plants/rocks) fall back to the
# old topple/die/clear behaviour.
func damage_sphere(world_pos: Vector3, radius: float, base_damage: float = 1000.0) -> void:
	var r2: float = radius * radius
	for actor in get_tree().get_nodes_in_group("selectable"):
		if not is_instance_valid(actor) or not (actor is Node3D):
			continue
		var a: Node3D = actor as Node3D
		var d2: float = a.global_position.distance_squared_to(world_pos)
		if d2 > r2:
			continue
		if a.has_method("take_damage"):
			var falloff: float = blast_falloff(sqrt(d2), radius)
			if falloff <= 0.0:
				continue
			# Fling scales with proximity too, so the killing blow throws the corpse outward.
			var away: Vector3 = a.global_position - world_pos
			away.y = absf(away.y) + 2.0
			var impulse: Vector3 = away.normalized() * (14.0 + 34.0 * falloff)
			a.take_damage(base_damage * falloff, "blast", impulse)
		elif a.has_method("topple"):
			# Trees don't vanish — the blast knocks them over, falling away from impact.
			var dir: Vector3 = a.global_position - world_pos
			dir.y = 0.0
			a.topple(dir)
		elif a.has_method("die"):
			var away: Vector3 = a.global_position - world_pos
			away.y = absf(away.y) + 2.0
			var force: float = 1.0 - a.global_position.distance_to(world_pos) / maxf(1.0, radius)
			a.die("meteor", away.normalized() * (14.0 + 34.0 * force))
		elif not a.is_in_group("corpse"):
			a.queue_free()


# Broadcast a felt/heard terror event (meteor impact, etc). Every creature within
# `radius` panics and sprints away, more intensely the closer it is.
func broadcast_scare(world_pos: Vector3, radius: float, base_intensity: float = 1.0) -> void:
	if radius <= 0.0:
		return
	for actor in get_tree().get_nodes_in_group("selectable"):
		if not is_instance_valid(actor) or not (actor is Node3D):
			continue
		if not actor.has_method("add_fear"):
			continue
		var d: float = (actor as Node3D).global_position.distance_to(world_pos)
		if d > radius:
			continue
		var closeness: float = 1.0 - (d / radius)          # 1 at impact, 0 at edge
		var panic_seconds: float = lerpf(2.0, 7.0, closeness) * base_intensity
		actor.call("add_fear", world_pos, panic_seconds)


func _physics_process(delta: float) -> void:
	if terrain == null or actors_root == null:
		return
	_process_pending()
	_breed_timer -= delta
	if _breed_timer <= 0.0:
		_breed_timer = 2.0
		_tick_breeding()
	_seed_timer -= delta
	if _seed_timer <= 0.0:
		_seed_timer = 1.5
		_tick_plant_seeding()
	_fish_timer -= delta
	if _fish_timer <= 0.0:
		_fish_timer = 2.5
		_tick_aquatic()
	_tree_timer -= delta
	if _tree_timer <= 0.0:
		_tree_timer = 1.4
		_tick_tree_seeding()


func _process_pending() -> void:
	if _pending.is_empty():
		return
	var still: Array = []
	for entry in _pending:
		var placed = _place_on_surface(entry["pos"])
		if placed != null:
			var k: String = String(entry["kind"])
			if (k == "tree" or k == "plant") and not _can_grow_here(placed):
				continue   # surface resolved somewhere too cold / snowy for vegetation — drop it
			var node = _instance_actor(k, placed, null, int(entry.get("family_id", -1)))
			if bool(entry.get("elder", false)):
				_seed_elder(node)   # a founder whose centre wasn't meshed at boot still becomes its band's elder
		else:
			entry["tries"] = int(entry["tries"]) + 1
			if int(entry["tries"]) < 300:      # keep retrying ~ a few seconds
				still.append(entry)
	_pending = still


func _tick_breeding() -> void:
	for kind in ["rabbit", "fox", "bird", "villager", "vulture"]:
		var cfg: Dictionary = _species_config(kind)
		var cap: int = int(cfg.get("pop_cap", 20))
		var group: String = "species_%s" % kind
		var members: Array = get_tree().get_nodes_in_group(group)
		if members.size() < 2 or members.size() >= cap:
			continue
		# count mature adults
		var adults: Array = []
		for m in members:
			if is_instance_valid(m) and m.has_method("is_mature") and m.is_mature():
				adults.append(m)
		if adults.size() < 2:
			continue
		if randf() > 0.5:
			continue                            # not every tick
		# TWO parents now: the offspring's genome is a crossover of theirs (traits + baked instincts),
		# plus mutation — so populations actually evolve instead of cloning a template.
		var pa: Node3D = adults[randi() % adults.size()] as Node3D
		var pb: Node3D = adults[randi() % adults.size()] as Node3D
		var guard: int = 0
		while pb == pa and guard < 4:
			pb = adults[randi() % adults.size()] as Node3D
			guard += 1
		# Breed AT a parent's nest if it has one — young are born at home and inherit the site.
		var base_pos: Vector3 = pa.global_position
		if bool(pa.get("has_nest")) and not is_inf(float((pa.get("nest_pos") as Vector3).x)):
			base_pos = pa.get("nest_pos")
		var placed = _place_on_surface(_tangent_offset_point(base_pos, randf_range(-2.0, 2.0), randf_range(-2.0, 2.0)))
		if placed != null:
			var child = _instance_actor(kind, placed, _breed_genome(pa, pb))
			_inherit_nest(pa, child)
			# Record the permanent lineage in the kinship graph: the child joins its parent's family component
			# (its family_id, inherited via the genome, is that same component's label) and the mate pair bond
			# is stored. Bonds are added once here and never rewritten.
			if child != null and is_instance_valid(child):
				_kinship.add_offspring(int(pa.get_instance_id()), int(child.get_instance_id()))
				_kinship.add_bond(int(pa.get_instance_id()), int(pb.get_instance_id()))


# HARNESS AID (--debug-family): deterministically produce a small family through the REAL reproduction path so
# the family-tree inspector has something to draw. Finds the first species with >=2 mature adults, breeds that
# pair twice (recording parent->child + the mate bond exactly as _tick_breeding does), then kills one child so a
# dead/greyed kin appears in the lineage. Returns a parent to root the tree on (null if no mature pair exists).
func debug_seed_family() -> Node:
	for kind in ["rabbit", "fox", "bird", "villager", "vulture"]:
		var adults: Array = []
		for m in get_tree().get_nodes_in_group("species_%s" % kind):
			if is_instance_valid(m) and m.has_method("is_mature") and m.is_mature():
				adults.append(m)
		if adults.size() < 2:
			continue
		var pa: Node3D = adults[0] as Node3D
		var pb: Node3D = adults[1] as Node3D
		var kids: Array = []
		for i in range(2):
			var placed = _place_on_surface(_tangent_offset_point(pa.global_position, randf_range(-2.0, 2.0), randf_range(-2.0, 2.0)))
			if placed == null:
				continue
			var child = _instance_actor(kind, placed, _breed_genome(pa, pb))
			if child != null and is_instance_valid(child):
				_inherit_nest(pa, child)
				_kinship.add_offspring(int(pa.get_instance_id()), int(child.get_instance_id()))
				_kinship.add_bond(int(pa.get_instance_id()), int(pb.get_instance_id()))
				kids.append(child)
		# Grey one branch: kill a child so the tree shows a dead kin while the lineage persists.
		if kids.size() >= 2 and kids[1].has_method("die"):
			kids[1].die("debug_family")
		return pa
	return null


# Natal philopatry: the offspring adopts a parent's home site, so kin CLUSTER in space over
# generations — which makes vision/sound social learning spread fastest among relatives (culture).
func _inherit_nest(parent, child) -> void:
	if child == null or not is_instance_valid(child):
		return
	if not bool(parent.get("has_nest")):
		return
	var np: Vector3 = parent.get("nest_pos")
	if is_inf(np.x):
		return
	child.set("nest_pos", np)
	child.set("has_nest", true)
	var nn = parent.get("_nest_node")
	if nn != null and is_instance_valid(nn) and nn.has_method("register_young"):
		nn.register_young()


# Place a shelter (LANest) at `site` for a nesting creature. Terrain-snapped for ground/water
# shelters; kept at the caller's Y for tree roosts (in_tree=true).
func spawn_nest(site: Vector3, nest_species: String, owner_family: int, in_tree: bool):
	if actors_root == null:
		return null
	var nest = NestScript.new()
	actors_root.add_child(nest)
	nest.global_position = site
	if nest.has_method("setup"):
		nest.setup(terrain, nest_species, owner_family, in_tree)
	return nest


# Build a child genome from two parents: rare Baldwin canalization of each parent's deepest lifelong
# habits into the germline, then crossover + mutation. The child inherits one parent's family line so
# kin preferentially learn from each other. Returns null (→ ancestral genome) if parents lack genomes.
func _breed_genome(pa, pb):
	var ga = pa.get_genome() if pa.has_method("get_genome") else null
	var gb = pb.get_genome() if pb.has_method("get_genome") else null
	if ga == null or gb == null:
		return null
	if pa.has_method("get_cognition") and pa.get_cognition() != null:
		ga.maybe_canalize(pa.get_cognition().policy)
	if pb.has_method("get_cognition") and pb.get_cognition() != null:
		gb.maybe_canalize(pb.get_cognition().policy)
	var child = LAGenome.crossover(ga, gb)
	child.mutate()
	# The child's family_id is its parent's connected-component label, sourced from the kinship graph (which
	# equals pa's stable family_id, since components never merge). The parent→child edge itself is recorded at
	# the breeding call site once the child node exists.
	child.base_config["family_id"] = _kinship.family_of(int(pa.get_instance_id()))
	return child


# Relay an animal call (alarm / distress / forage) to everything in earshot. Omnidirectional: each
# listener decides by its OWN hearing_range, so no line of sight is needed — this is how a sentinel's
# screech flushes a whole herd and how food calls teach kin past the vision cone.
func broadcast_call(world_pos: Vector3, from_species: String, call_type: String, caller) -> void:
	for actor in get_tree().get_nodes_in_group("creature"):
		if actor == caller or not is_instance_valid(actor) or not (actor is Node3D):
			continue
		if not actor.has_method("hear_call"):
			continue
		var hr: float = float(actor.get("hearing_range"))
		if (actor as Node3D).global_position.distance_to(world_pos) <= hr:
			actor.call("hear_call", world_pos, from_species, call_type, caller)


# Grow a plant at world_pos if the plant population is under its cap. Called by LAMaterialScent3D where
# soil FERTILITY is richest (dung fertilizes → grass sprouts) and by wildfire ash regrowth.
func seed_plant_at(world_pos: Vector3) -> void:
	var cap: int = int(_plant_config().get("pop_cap", 120))
	if get_tree().get_nodes_in_group("plant").size() >= cap:
		return
	spawn("plant", world_pos)


# Seed a modest starting population of every aquatic species into water matching its band. Called once
# after the sea level is locked. Ongoing recovery is handled by _tick_aquatic; this just makes the sea
# and lakes feel alive from the first frame instead of trickling in.
func stock_initial_aquatic() -> void:
	for kind in _aquatic_kinds():
		var cfg: Dictionary = _species_config(String(kind))
		var initial: int = int(round(float(cfg.get("initial", 0)) * AQUATIC_STOCK_MULT))
		for i in range(initial):
			var wet: Vector3 = _random_aquatic_point(cfg)
			if not is_nan(wet.x):
				_instance_actor(String(kind), wet)


# Keep the water stocked with every aquatic species. Each appears (and recovers) only where water in
# its OWN salinity/depth band exists, so species self-sort: freshwater fish into lakes, salt species out
# in the deep sea, brackish species along the coast — no hand-placed spawn points, all emergent. One
# individual of one under-cap species is added per tick.
func _tick_aquatic() -> void:
	for kind in _aquatic_kinds():
		var cfg: Dictionary = _species_config(String(kind))
		var cap: int = int(round(float(cfg.get("pop_cap", 12)) * AQUATIC_STOCK_MULT))
		if get_tree().get_nodes_in_group("species_%s" % String(kind)).size() >= cap:
			continue
		var wet: Vector3 = _random_aquatic_point(cfg)
		if is_nan(wet.x):
			continue
		_instance_actor(String(kind), wet)
		return                                       # one spawn per tick keeps the stocking gentle


# Sample the sea for a point inside a species' depth band: pick a random direction where the GROUND surface
# sits below sea level, then place the individual somewhere in the underwater shell between the seabed and the
# sea radius, inside the species' depth band. Everything is radial (no XZ column reads — three-d-always), so
# species self-sort into the right water with no hand-placed spawn points. NAN-x vector if none found.
func _random_aquatic_point(cfg: Dictionary) -> Vector3:
	var dmin: float = float(cfg.get("depth_min", 0.0))
	var dmax: float = float(cfg.get("depth_max", 999.0))
	var pc: Vector3 = terrain.planet_center()
	var sea_r: float = terrain.sea_radius()
	for i in range(AQUATIC_SAMPLE_TRIES):
		var dir: Vector3 = _random_sphere_dir()
		var ground_r: float = terrain.surface_radius(dir)
		if is_nan(ground_r) or ground_r >= sea_r:
			continue                                  # unmeshed, or dry land poking above sea level
		var lo: float = maxf(ground_r, sea_r - dmax)  # deepest allowed (clamped to just above the seabed)
		var hi: float = sea_r - dmin                  # shallowest allowed (just below the surface)
		if hi <= lo:
			continue
		return pc + dir * randf_range(lo, hi)
	return Vector3(NAN, 0.0, 0.0)


func _tick_plant_seeding() -> void:
	var plants: Array = get_tree().get_nodes_in_group("plant")
	var cap: int = int(_plant_config().get("pop_cap", 120))
	if plants.size() >= cap:
		return
	for p in plants:
		if not is_instance_valid(p):
			continue
		if p.has_method("has_seed") and p.has_seed():
			if randf() > 0.4:
				continue
			var placed = _place_on_surface(_tangent_offset_point((p as Node3D).global_position, randf_range(-3.5, 3.5), randf_range(-3.5, 3.5)))
			if placed != null and _can_grow_here(placed):
				_instance_actor("plant", placed)   # seed only takes on warm, snow-free ground (emergent treeline)
			if p.has_method("consume"):
				p.consume()
			if get_tree().get_nodes_in_group("plant").size() >= cap:
				return


# FOREST SUCCESSION — the emergent grove-builder. Each tick a few existing trees standing on biomass-rich
# ground drop a seedling into their tangent neighbourhood, but ONLY where the local biomass the photosynthesis
# chemistry has fixed clears an adaptive threshold (a fraction of the richest grove's biomass). So forests
# THICKEN on the warm fertile continents that grew the most biomass, spread out from existing trees (groves,
# not scatter), and stall at cold/snowy/coastal margins where biomass never crosses the bar or the treeline
# gate blocks germination. Forests are a consequence of the chemistry, not a placement table.
const TREE_POP_CAP: int = 400               # forest carrying capacity (well above the initial seed count)
const TREE_SEED_BIOMASS_FRAC: float = 0.35  # seed only onto ground with >= this fraction of the richest grove's biomass
const TREE_SEED_FLOOR: float = 0.04         # absolute biomass floor so bare/cold ground never seeds
const TREE_SEED_SPREAD: float = 8.0         # how far a seedling lands from its parent (grove tightness, metres)
const TREE_SEEDS_PER_TICK: int = 10         # parents that attempt to seed per tick (bounded work — big-O by tick, not grid)
func _tick_tree_seeding() -> void:
	var trees: Array = get_tree().get_nodes_in_group("tree")
	if trees.is_empty() or trees.size() >= TREE_POP_CAP:
		return
	# The richest grove's biomass sets an ADAPTIVE bar (self-scales to whatever the chemistry produces), so
	# the forest advances onto ground within TREE_SEED_BIOMASS_FRAC of the best fertility.
	var peak: float = 0.0
	for t in trees:
		if is_instance_valid(t):
			peak = maxf(peak, _biomass_at((t as Node3D).global_position))
	var thresh: float = maxf(TREE_SEED_FLOOR, peak * TREE_SEED_BIOMASS_FRAC)
	var seeded: int = 0
	var guard: int = 0
	while seeded < TREE_SEEDS_PER_TICK and guard < TREE_SEEDS_PER_TICK * 4:
		guard += 1
		var parent: Node3D = trees[randi() % trees.size()] as Node3D
		if not is_instance_valid(parent) or _biomass_at(parent.global_position) < thresh:
			continue                                # parent isn't on rich enough ground to spread a grove
		seeded += 1
		var placed = _place_on_surface(_tangent_offset_point(parent.global_position, randf_range(-TREE_SEED_SPREAD, TREE_SEED_SPREAD), randf_range(-TREE_SEED_SPREAD, TREE_SEED_SPREAD)))
		if placed == null or _is_water_pos(placed) or not _can_grow_here(placed):
			continue                                # off the treeline / into the sea — the grove's edge
		if _biomass_at(placed) < thresh:
			continue                                # seedling site not fertile enough — keeps groves dense, not scattered
		_instance_actor("tree", placed)
		if get_tree().get_nodes_in_group("tree").size() >= TREE_POP_CAP:
			return
