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
const FireSystemScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/FireSystem.gd")

const KINDS: Array = ["plant", "rabbit", "fox", "bird", "villager", "fish", "rock", "tree"]
const FISH_CAP: int = 26

var terrain = null                       # LAVoxelTerrainService
var actors_root: Node3D = null
var _scent = null                        # LAScentField (observer; creatures query it)
var _tracks = null                       # LATrackSystem (observer; footprints)
var _material = null                      # LAMaterialField — the ONE substrate (water/heat/materials)
var _fire = null                         # LAFireSystem (wildfire spread over flammable actors)
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


# --- species / plant configs ------------------------------------------------
func _species_config(kind: String) -> Dictionary:
	match kind:
		"rabbit":
			return {
				"species": "rabbit", "diet": "herbivore",
				"speed": 3.6, "size": 0.55, "color": Color(0.72, 0.58, 0.44),
				"can_fly": false, "sense_radius": 9.0, "maturity_age": 14.0,
				"preys_on": PackedStringArray(),
				"flees_from": PackedStringArray(["fox", "villager"]),
				"herd": true, "pop_cap": 40,
				# Low stamina: sprinting from a persistence hunter exhausts them.
				"max_energy": 70.0, "metabolism": 2.6, "food_value": 50.0,
				"thirst_rate": 1.4,
				# Loose, skittish ground herd: modest cohesion, strong separation;
				# breaks apart the instant a predator is near.
				"flock_cohesion": 0.6, "flock_alignment": 0.55,
				"flock_separation": 1.1, "flock_radius": 8.0, "flock_weight": 0.9,
				# Side-set eyes: near-panoramic FOV (small rear blind spot), shallow reach; sharp ears.
				"eye_fov": 320.0, "hearing_range": 16.0,
			}
		"fox":
			return {
				"species": "fox", "diet": "carnivore",
				"speed": 4.6, "size": 0.8, "color": Color(0.82, 0.36, 0.12),
				"can_fly": false, "sense_radius": 16.0, "maturity_age": 20.0,
				"preys_on": PackedStringArray(["rabbit", "fish"]),
				"flees_from": PackedStringArray(),
				"herd": false, "pop_cap": 12, "nocturnal": true,
				"max_energy": 130.0, "metabolism": 2.0, "food_value": 70.0,
				"thirst_rate": 1.0,
				# Semi-solitary: weak cohesion so they never clump, some alignment,
				# healthy personal space.
				"flock_cohesion": 0.25, "flock_alignment": 0.4,
				"flock_separation": 0.85, "flock_radius": 12.0, "flock_weight": 0.5,
				# Forward-set eyes: narrow binocular cone → depth perception → longer reach to spot prey.
				"eye_fov": 100.0, "hearing_range": 18.0,
			}
		"bird":
			return {
				"species": "bird", "diet": "herbivore",
				"speed": 6.5, "size": 0.4, "color": Color(0.30, 0.52, 0.85),
				"can_fly": true, "cruise_height": 14.0,
				"sense_radius": 13.0, "maturity_age": 11.0,
				"preys_on": PackedStringArray(),
				"flees_from": PackedStringArray(),
				"herd": true, "pop_cap": 30,
				"max_energy": 60.0, "metabolism": 2.0, "food_value": 30.0,
				"thirst_rate": 0.6,
				# Tight, fast, highly-aligned 3D aerial flock: alignment and
				# cohesion dominate over a large perception radius.
				"flock_cohesion": 0.9, "flock_alignment": 1.2,
				"flock_separation": 0.7, "flock_radius": 18.0, "flock_weight": 1.4,
				# Wide avian FOV, keen at distance; excellent hearing across the flock.
				"eye_fov": 300.0, "hearing_range": 20.0,
			}
		"villager":
			return {
				"species": "villager", "diet": "omnivore",
				"speed": 3.0, "size": 1.0, "color": Color(0.85, 0.72, 0.55),
				"can_fly": false, "sense_radius": 14.0, "maturity_age": 26.0,
				"preys_on": PackedStringArray(["rabbit", "fox", "fish"]),
				"flees_from": PackedStringArray(),
				"herd": true, "pop_cap": 16,
				# Endurance apex: high stamina, hunts by persistence + thrown rocks,
				# scavenges anything. Slower than prey, so it wears them down.
				"max_energy": 160.0, "metabolism": 1.4, "food_value": 90.0,
				"thirst_rate": 1.1,
				"throws": true, "throw_range": 15.0,
				# Loose social groups: balanced cohesion + alignment, moderate
				# spacing — they gather but keep an arm's length.
				"flock_cohesion": 0.7, "flock_alignment": 0.7,
				"flock_separation": 0.7, "flock_radius": 10.0, "flock_weight": 0.9,
				# Forward-facing hominin eyes: binocular hunter's reach, good all-round hearing.
				"eye_fov": 120.0, "hearing_range": 16.0,
			}
		_:
			return {}


func _fish_config() -> Dictionary:
	return {
		"species": "fish", "speed": randf_range(2.2, 3.2), "size": randf_range(0.28, 0.42),
		"color": Color(0.60, 0.70, 0.84).lerp(Color(0.75, 0.62, 0.5), randf() * 0.4),
		"sense_radius": 9.0, "maturity_age": 12.0, "food_value": 26.0,
		"max_age": randf_range(110.0, 160.0),
	}


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
	_fire = FireSystemScript.new()
	_fire.name = "FireSystem"
	add_child(_fire)
	_fire.setup(self)
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
	# Fire reads the field for heat-driven ignition/spread (set after fire is created in setup()).
	if _fire != null and _fire.has_method("set_material_field"):
		_fire.set_material_field(_material)


func material_field():
	return _material


func fire_system():
	return _fire


func cognition_scheduler():
	return _cognition_sched


# Ignite flammable actors within radius of a point (meteor strike, etc.).
func ignite_area(world_pos: Vector3, radius: float) -> void:
	if _fire != null and _fire.has_method("ignite_area"):
		_fire.ignite_area(world_pos, radius)


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
	elif kind == "fish":
		# Fish only exist in water: refuse to place one on dry ground.
		if _material == null or not _material.has_method("is_water_at") or not _material.is_water_at(placed.x, placed.z):
			return null
		var fish: FishScript = FishScript.new()
		actors_root.add_child(fish)
		fish.global_position = placed
		fish.setup(terrain, _material, _fish_config())
		node = fish
	else:
		var cfg: Dictionary = _species_config(kind)
		if cfg.is_empty():
			push_warning("LAEcologyService: unknown kind '%s'" % kind)
			return null
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


func damage_sphere(world_pos: Vector3, radius: float) -> void:
	# Meteor impact: creatures die into flung corpses; plants/rocks are cleared.
	var r2: float = radius * radius
	for actor in get_tree().get_nodes_in_group("selectable"):
		if not is_instance_valid(actor) or not (actor is Node3D):
			continue
		var a: Node3D = actor as Node3D
		if a.global_position.distance_squared_to(world_pos) > r2:
			continue
		if a.has_method("topple"):
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
		_tick_fish()


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
	for kind in ["rabbit", "fox", "bird", "villager"]:
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
		var placed = _place_on_surface(pa.global_position + offset)
		if placed != null:
			_instance_actor(kind, placed, _breed_genome(pa, pb))


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


# Keep lakes/rivers stocked with fish. Fish appear (and recover) only where water has
# actually pooled, so they emerge wherever the water field decides to form water bodies —
# no hand-placed spawn points. One fish added per tick until the cap is reached.
func _tick_fish() -> void:
	if _material == null or not _material.has_method("is_water_at"):
		return
	if get_tree().get_nodes_in_group("species_fish").size() >= FISH_CAP:
		return
	var wet: Vector3 = _random_wet_point()
	if is_nan(wet.x):
		return
	_instance_actor("fish", wet)


# Sample random points across the play area for one that sits over water; returns a
# surface-projected point, or a NAN-x vector if no water was found this tick.
func _random_wet_point() -> Vector3:
	for i in range(24):
		var x: float = randf_range(-spawn_extent, spawn_extent)
		var z: float = randf_range(-spawn_extent, spawn_extent)
		if _material.is_water_at(x, z):
			var placed = _place_on_surface(Vector3(x, 0.0, z))
			if placed != null:
				return placed
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
			var offset: Vector3 = Vector3(randf_range(-3.5, 3.5), 0.0, randf_range(-3.5, 3.5))
			var placed = _place_on_surface((p as Node3D).global_position + offset)
			if placed != null:
				_instance_actor("plant", placed)
			if p.has_method("consume"):
				p.consume()
			if get_tree().get_nodes_in_group("plant").size() >= cap:
				return
