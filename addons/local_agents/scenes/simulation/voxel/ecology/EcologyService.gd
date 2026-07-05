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
const ScentFieldScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ScentField.gd")
const TrackSystemScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/TrackSystem.gd")
const NestScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Nest.gd")

const KINDS: Array = ["plant", "rabbit", "fox", "bird", "villager", "fish", "rock", "tree"]

# Aquatic life is stocked out over a wide radius (the ocean rings the island beyond ~180u; freshwater
# lakes/rivers sit inland) — much wider than the land-creature spawn_extent. Kept a little inside the
# 300u world/material half-extent so samples land on sampled cells.
const AQUATIC_EXTENT: float = 285.0
const AQUATIC_SAMPLE_TRIES: int = 60

var terrain = null                       # LAVoxelTerrainService
var actors_root: Node3D = null
var _scent = null                        # LAScentField (observer; creatures query it)
var _tracks = null                       # LATrackSystem (observer; footprints)
var _material = null                      # LAMaterialField — the ONE substrate (water/heat/materials)
var _cognition_sched = null              # LACognitionScheduler (shared slow-brain budget/queue)

# world spawn area (XZ half-extent) used for spawn_initial scatter
var spawn_extent: float = 80.0

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
var _aquatic_kinds_cache: Array = []     # aquatic species ids (config aquatic:true), indexed once
var _aquatic_indexed: bool = false

# --- Seismic stimulus (emergent camera shake) --------------------------------
# Every ground disturbance emits a short-lived seismic PULSE into this capped ring. The camera (and
# any other listener) queries seismic_energy_at() and shakes in proportion to nearby energy × proximity
# — so shake FALLS OUT of ground motion; no event tells the camera to shake. Pulses age out fast.
const SEISMIC_LIFETIME: float = 0.8          # seconds a pulse stays "felt" before it fully decays
const SEISMIC_BASE_RANGE: float = 70.0       # felt radius of a unit-magnitude pulse (grows with magnitude)
const SEISMIC_RANGE_PER_MAG: float = 25.0    # extra felt radius per unit of magnitude
const SEISMIC_MAX_PULSES: int = 64           # cap the ring so a storm of disturbances stays cheap
var _seismic_pulses: Array = []              # [{pos: Vector3, mag: float, age: float}]


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
	# Decoupled observer systems: scent trails (predators track prey) + footprints.
	_scent = ScentFieldScript.new()
	_scent.name = "ScentField"
	add_child(_scent)
	_scent.setup(terrain)
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


func scent_field():
	return _scent


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


# Emit a seismic PULSE at world_pos with the given magnitude (energy). Recorded in a small capped ring
# that ages out; seismic_energy_at() sums live pulses with distance + time falloff. This is the ONE
# stimulus every ground-disturbing event feeds, so shake is emergent and never per-event scripted.
# Impacts that don't route through disturb_ground (lava-bomb landings, etc.) call this directly.
func broadcast_seismic(world_pos: Vector3, magnitude: float) -> void:
	if magnitude <= 0.0:
		return
	_seismic_pulses.append({"pos": world_pos, "mag": magnitude, "age": 0.0})
	if _seismic_pulses.size() > SEISMIC_MAX_PULSES:
		_seismic_pulses.pop_front()


# Sum the seismic energy felt at world_pos from all live pulses. Each contributes its magnitude scaled
# by a squared distance falloff (worse the nearer the source — proximity is automatic) and a linear time
# decay as the pulse ages out. Cheap: the ring is capped and expired pulses are dropped each step.
func seismic_energy_at(world_pos: Vector3) -> float:
	var energy: float = 0.0
	for pulse in _seismic_pulses:
		var mag: float = float(pulse["mag"])
		var reach: float = SEISMIC_BASE_RANGE + mag * SEISMIC_RANGE_PER_MAG
		var d: float = (pulse["pos"] as Vector3).distance_to(world_pos)
		var near: float = clampf(1.0 - d / reach, 0.0, 1.0)
		if near <= 0.0:
			continue
		var life: float = clampf(1.0 - float(pulse["age"]) / SEISMIC_LIFETIME, 0.0, 1.0)
		energy += mag * near * near * life
	return energy


# Age the seismic ring each physics step and drop pulses that have fully decayed.
func _age_seismic(delta: float) -> void:
	if _seismic_pulses.is_empty():
		return
	var live: Array = []
	for pulse in _seismic_pulses:
		pulse["age"] = float(pulse["age"]) + delta
		if float(pulse["age"]) < SEISMIC_LIFETIME:
			live.append(pulse)
	_seismic_pulses = live


func cognition_scheduler():
	return _cognition_sched


# A hot event "starts a fire" only by depositing heat — vegetation there ignites on the next
# combustion scan because its cell crossed the ignition temperature. Pure emergence, no fire code.
func ignite_area(world_pos: Vector3, radius: float) -> void:
	if _material != null and _material.has_method("add_heat"):
		_material.add_heat(world_pos, 900.0, radius)   # ~3x wood's 300°C ignition temp


func spawn(kind: String, world_pos: Vector3) -> Node:
	if actors_root == null:
		push_warning("LAEcologyService.spawn before setup()")
		return null
	var placed = _place_on_surface(world_pos)
	if placed == null:
		# surface not ready: queue for retry, return null (caller may ignore)
		_pending.append({"kind": kind, "pos": world_pos, "tries": 0})
		return null
	return _instance_actor(kind, placed)


func spawn_initial(counts: Dictionary) -> void:
	for kind in counts.keys():
		var n: int = int(counts[kind])
		for i in n:
			var p: Vector3 = _random_spawn_point()
			var placed = _place_on_surface(p)
			if placed == null:
				_pending.append({"kind": String(kind), "pos": p, "tries": 0})
			else:
				_instance_actor(String(kind), placed)


func _random_spawn_point() -> Vector3:
	var x: float = randf_range(-spawn_extent, spawn_extent)
	var z: float = randf_range(-spawn_extent, spawn_extent)
	return Vector3(x, 0.0, z)


# Resolve a surface Y for a horizontal position. Returns a positioned Vector3, or
# null if the terrain isn't meshed there yet.
func _place_on_surface(world_pos: Vector3):
	if terrain == null:
		return null
	var y: float = NAN
	if terrain.has_method("surface_height"):
		y = float(terrain.surface_height(world_pos.x, world_pos.z))
	if is_nan(y):
		return null
	return Vector3(world_pos.x, y, world_pos.z)


func _instance_actor(kind: String, placed: Vector3, genome = null) -> Node:
	var node: Node = null
	if kind == "plant":
		var plant: PlantScript = PlantScript.new()
		actors_root.add_child(plant)
		plant.global_position = placed
		plant.setup(terrain, _plant_config())
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
			if _material == null or not _material.has_method("is_water_at") or not _material.is_water_at(placed.x, placed.z):
				return null
			var fish: FishScript = FishScript.new()
			actors_root.add_child(fish)
			fish.global_position = placed
			fish.setup(terrain, _material, cfg)
			return fish
		var creature: CreatureScript = CreatureScript.new()
		actors_root.add_child(creature)
		creature.global_position = placed
		creature.setup(terrain, cfg, genome)          # genome (if bred) drives traits + instincts
		if creature.has_method("set_scent"):
			creature.set_scent(_scent)
		if creature.has_method("set_ecology"):
			creature.set_ecology(self)
		if creature.has_method("set_material_field"):
			creature.set_material_field(_material)
		if creature.has_method("set_cognition_scheduler"):
			creature.set_cognition_scheduler(_cognition_sched)
		node = creature
	return node


func _tree_config() -> Dictionary:
	var pine: bool = randf() < 0.4
	return {"species": "pine" if pine else "oak"}


# Scatter ambient rocks and clustered forests across the world (independent of meteors).
func populate_environment(rock_count: int, forest_clusters: int) -> void:
	for i in rock_count:
		spawn("rock", _random_spawn_point())
	for c in forest_clusters:
		var center: Vector3 = _random_spawn_point()
		var trees: int = randi_range(7, 15)
		for t in trees:
			var off: Vector3 = Vector3(randf_range(-14, 14), 0, randf_range(-14, 14))
			spawn("tree", center + off)


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
	_age_seismic(delta)
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


func _process_pending() -> void:
	if _pending.is_empty():
		return
	var still: Array = []
	for entry in _pending:
		var placed = _place_on_surface(entry["pos"])
		if placed != null:
			_instance_actor(String(entry["kind"]), placed)
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
		var offset: Vector3 = Vector3(randf_range(-2.0, 2.0), 0.0, randf_range(-2.0, 2.0))
		# Breed AT a parent's nest if it has one — young are born at home and inherit the site.
		var base_pos: Vector3 = pa.global_position
		if bool(pa.get("has_nest")) and not is_inf(float((pa.get("nest_pos") as Vector3).x)):
			base_pos = pa.get("nest_pos")
		var placed = _place_on_surface(base_pos + offset)
		if placed != null:
			var child = _instance_actor(kind, placed, _breed_genome(pa, pb))
			_inherit_nest(pa, child)


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
	var fam: int = int(pa.get_family_id()) if pa.has_method("get_family_id") else 0
	child.base_config["family_id"] = fam
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


# A creature dropped this poop: connect its fertilize request so dung emergently
# grows a new plant on the enriched patch (respecting the plant population cap).
func register_poop(poop) -> void:
	if poop == null or not poop.has_signal("wants_seed"):
		return
	if not poop.wants_seed.is_connected(seed_plant_at):
		poop.wants_seed.connect(seed_plant_at)


# Grow a plant at world_pos if the plant population is under its cap. Shared by dung
# fertilization (register_poop) and, later, wildfire ash regrowth.
func seed_plant_at(world_pos: Vector3) -> void:
	var cap: int = int(_plant_config().get("pop_cap", 120))
	if get_tree().get_nodes_in_group("plant").size() >= cap:
		return
	spawn("plant", world_pos)


# Seed a modest starting population of every aquatic species into water matching its band. Called once
# after the sea level is locked. Ongoing recovery is handled by _tick_aquatic; this just makes the sea
# and lakes feel alive from the first frame instead of trickling in.
func stock_initial_aquatic() -> void:
	if _material == null or not _material.has_method("is_water_at"):
		return
	for kind in _aquatic_kinds():
		var cfg: Dictionary = _species_config(String(kind))
		var initial: int = int(cfg.get("initial", 0))
		for i in range(initial):
			var wet: Vector3 = _random_aquatic_point(cfg)
			if not is_nan(wet.x):
				_instance_actor(String(kind), wet)


# Keep the water stocked with every aquatic species. Each appears (and recovers) only where water in
# its OWN salinity/depth band exists, so species self-sort: freshwater fish into lakes, salt species out
# in the deep sea, brackish species along the coast — no hand-placed spawn points, all emergent. One
# individual of one under-cap species is added per tick.
func _tick_aquatic() -> void:
	if _material == null or not _material.has_method("is_water_at"):
		return
	for kind in _aquatic_kinds():
		var cfg: Dictionary = _species_config(String(kind))
		var cap: int = int(cfg.get("pop_cap", 12))
		if get_tree().get_nodes_in_group("species_%s" % String(kind)).size() >= cap:
			continue
		var wet: Vector3 = _random_aquatic_point(cfg)
		if is_nan(wet.x):
			continue
		_instance_actor(String(kind), wet)
		return                                       # one spawn per tick keeps the stocking gentle


# Sample the water for a point inside a species' salinity + depth band; returns a surface-projected
# point, or a NAN-x vector if none was found this tick. This is what places each species into the right
# water (fresh / brackish / salt, shallow / deep) without a single per-species branch.
func _random_aquatic_point(cfg: Dictionary) -> Vector3:
	var smin: float = float(cfg.get("salinity_min", 0.0))
	var smax: float = float(cfg.get("salinity_max", 1.0))
	var dmin: float = float(cfg.get("depth_min", 0.0))
	var dmax: float = float(cfg.get("depth_max", 999.0))
	for i in range(AQUATIC_SAMPLE_TRIES):
		var x: float = randf_range(-AQUATIC_EXTENT, AQUATIC_EXTENT)
		var z: float = randf_range(-AQUATIC_EXTENT, AQUATIC_EXTENT)
		if not _material.is_water_at(x, z):
			continue
		var s: float = _material.salinity_at(x, z)
		if is_nan(s) or s < smin or s > smax:
			continue
		var placed = _place_on_surface(Vector3(x, 0.0, z))
		if placed == null:
			continue
		var depth: float = _aquatic_depth(x, z, placed)
		if not is_nan(depth) and (depth < dmin or depth > dmax):
			continue
		return placed
	return Vector3(NAN, 0.0, 0.0)


# Water-column depth (surface Y minus seabed/lakebed) at a sampled point; NAN if unavailable. Mirrors
# LAFish's own depth read so stocking places a species where its depth band will keep it.
func _aquatic_depth(x: float, z: float, placed: Vector3) -> float:
	if not _material.has_method("surface_y_at"):
		return NAN
	var surf: float = _material.surface_y_at(x, z)
	if is_nan(surf):
		return NAN
	return surf - placed.y


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
			var offset: Vector3 = Vector3(randf_range(-3.5, 3.5), 0.0, randf_range(-3.5, 3.5))
			var placed = _place_on_surface((p as Node3D).global_position + offset)
			if placed != null:
				_instance_actor("plant", placed)
			if p.has_method("consume"):
				p.consume()
			if get_tree().get_nodes_in_group("plant").size() >= cap:
				return
