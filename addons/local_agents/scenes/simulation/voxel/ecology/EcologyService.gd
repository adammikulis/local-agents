class_name LAEcologyService
extends Node

# Drives the living world: spawning, predator-prey population dynamics, breeding
# with population caps, herd cohesion (delegated to creatures), and plant seeding.
# Every actor is placed on the terrain surface via LAVoxelTerrainService.

const CreatureScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Creature.gd")
const PlantScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Plant.gd")
const RockScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Rock.gd")
const TreeScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/actors/Tree.gd")
const ScentFieldScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ScentField.gd")
const TrackSystemScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/TrackSystem.gd")

const KINDS: Array = ["plant", "rabbit", "fox", "bird", "villager", "rock", "tree"]

var terrain = null                       # LAVoxelTerrainService
var actors_root: Node3D = null
var _scent = null                        # LAScentField (observer; creatures query it)
var _tracks = null                       # LATrackSystem (observer; footprints)
var _water = null                        # LAWaterFieldSystem (observer; creatures/fish query it)

# world spawn area (XZ half-extent) used for spawn_initial scatter
var spawn_extent: float = 80.0

# pending spawns whose surface wasn't ready yet: [{kind, pos, tries}]
var _pending: Array = []
var _breed_timer: float = 0.0
var _seed_timer: float = 0.0


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
				# Loose, skittish ground herd: modest cohesion, strong separation;
				# breaks apart the instant a predator is near.
				"flock_cohesion": 0.6, "flock_alignment": 0.55,
				"flock_separation": 1.1, "flock_radius": 8.0, "flock_weight": 0.9,
			}
		"fox":
			return {
				"species": "fox", "diet": "carnivore",
				"speed": 4.6, "size": 0.8, "color": Color(0.82, 0.36, 0.12),
				"can_fly": false, "sense_radius": 16.0, "maturity_age": 20.0,
				"preys_on": PackedStringArray(["rabbit"]),
				"flees_from": PackedStringArray(),
				"herd": false, "pop_cap": 12,
				"max_energy": 130.0, "metabolism": 2.0, "food_value": 70.0,
				# Semi-solitary: weak cohesion so they never clump, some alignment,
				# healthy personal space.
				"flock_cohesion": 0.25, "flock_alignment": 0.4,
				"flock_separation": 0.85, "flock_radius": 12.0, "flock_weight": 0.5,
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
				# Tight, fast, highly-aligned 3D aerial flock: alignment and
				# cohesion dominate over a large perception radius.
				"flock_cohesion": 0.9, "flock_alignment": 1.2,
				"flock_separation": 0.7, "flock_radius": 18.0, "flock_weight": 1.4,
			}
		"villager":
			return {
				"species": "villager", "diet": "omnivore",
				"speed": 3.0, "size": 1.0, "color": Color(0.85, 0.72, 0.55),
				"can_fly": false, "sense_radius": 14.0, "maturity_age": 26.0,
				"preys_on": PackedStringArray(["rabbit", "fox"]),
				"flees_from": PackedStringArray(),
				"herd": true, "pop_cap": 16,
				# Endurance apex: high stamina, hunts by persistence + thrown rocks,
				# scavenges anything. Slower than prey, so it wears them down.
				"max_energy": 160.0, "metabolism": 1.4, "food_value": 90.0,
				"throws": true, "throw_range": 15.0,
				# Loose social groups: balanced cohesion + alignment, moderate
				# spacing — they gather but keep an arm's length.
				"flock_cohesion": 0.7, "flock_alignment": 0.7,
				"flock_separation": 0.7, "flock_radius": 10.0, "flock_weight": 0.9,
			}
		_:
			return {}


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


func scent_field():
	return _scent


func set_water(w) -> void:
	_water = w


func water_field():
	return _water


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


func _instance_actor(kind: String, placed: Vector3) -> Node:
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
		var creature: CreatureScript = CreatureScript.new()
		actors_root.add_child(creature)
		creature.global_position = placed
		creature.setup(terrain, cfg)
		if creature.has_method("set_scent"):
			creature.set_scent(_scent)
		if creature.has_method("set_ecology"):
			creature.set_ecology(self)
		if creature.has_method("set_water"):
			creature.set_water(_water)
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
		if a.has_method("die"):
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
		var parent: Node3D = adults[randi() % adults.size()] as Node3D
		var offset: Vector3 = Vector3(randf_range(-2.0, 2.0), 0.0, randf_range(-2.0, 2.0))
		var placed = _place_on_surface(parent.global_position + offset)
		if placed != null:
			_instance_actor(kind, placed)


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
