@tool
class_name LocalAgentCreatureSpawner
extends Node3D

## Drop this node into a scene, type how many of each species you want, press play: you get a population of
## standalone LocalAgentCreatures scattered around it, optionally standing on a floor it builds for you. It is
## the no-code form of the spawn loop every demo used to write by hand (instantiate Creature.tscn, position it,
## call setup_standalone, repeat) — see examples/ThinkingCreatureDemo.gd for that loop in GDScript.
##
## The creatures it makes are STANDALONE ones: a flat-ground terrain adapter at `ground_y`, no MaterialField,
## no ecology, no planet — their pure fast/reinforced brain. Assign `cognition_scheduler` and turn on
## `llm_enabled` to also let them escalate to a language model.
##
## @tool is here only for the inspector warnings; _ready returns immediately in the editor, so a spawner in an
## open scene never populates it. Call spawn() yourself from an editor script if you want that.
##
## (Explicit types only — project rule: no ':=' inferred typing.)

const CreatureScene: PackedScene = preload("res://addons/local_agents/creatures/Creature.tscn")

@export_group("Population")
## Species id -> how many to spawn, e.g. {"rabbit": 5, "fox": 1}. Ids are the file names under
## creatures/species/**/<id>.json. A blank id is not valid here — name a species.
## Typed so the inspector gives you String keys and int values instead of a free-for-all. From code,
## assign it directly (`spawner.counts = {"rabbit": 5}` converts fine); `set("counts", {...})` with
## an untyped literal is silently dropped, so pass a typed local if you must go through set().
@export var counts: Dictionary[String, int] = {"rabbit": 5}:
	set(value):
		counts = value
		_refresh_warnings()

@export_group("Placement")
## Full width/height/depth in METRES of the box creatures are scattered inside, centred on this node.
## Leave Y at 0 to keep everything on the ground plane; the creatures snap to the ground either way.
## (No range hint: Godot 4.7 rejects @export_range on Vector3 — it only accepts float-ish types.)
@export var area_extent: Vector3 = Vector3(16.0, 0.0, 16.0):
	set(value):
		area_extent = value
		_refresh_warnings()
## World Y of the flat ground plane the creatures stand on (and where the convenience floor is built).
@export_range(-1000.0, 1000.0, 0.05, "or_less", "or_greater", "suffix:m") var ground_y: float = 0.0
## Populate automatically when the scene starts. Turn off to call spawn() yourself.
@export var spawn_on_ready: bool = true
## Seed for the scatter, so the same scene lays out identically every run. Change it for a different layout.
@export_range(0, 65535, 1, "or_greater") var placement_seed: int = 0

@export_group("Convenience")
## Also build a plain visible + collidable floor at Ground Y, so a spawner alone is a runnable scene.
## Turn it off when your scene already has ground.
@export var build_floor: bool = true
## Side length of that convenience floor (it is square, centred on this node).
@export_range(1.0, 500.0, 1.0, "suffix:m") var floor_size: float = 80.0
## Colour of that convenience floor.
@export_color_no_alpha var floor_color: Color = Color(0.32, 0.45, 0.28)

@export_group("Cognition")
## Scheduler these creatures escalate through (a LocalAgent-backed slow brain). Leave it empty for fast
## rules only, or if something else in the scene already hands them a scheduler.
@export var cognition_scheduler: LocalAgentCognitionScheduler = null:
	set(value):
		cognition_scheduler = value
		_refresh_warnings()
## Let the spawned creatures escalate novel situations to the language model. Off = fast rules only,
## whatever else the scene provides. On, they escalate as soon as they have a scheduler.
@export var llm_enabled: bool = false:
	set(value):
		llm_enabled = value
		_refresh_warnings()

var _creatures: Array[Node] = []


func _ready() -> void:
	if Engine.is_editor_hint():
		return                            # @tool is for the inspector warnings only — never populate in-editor
	if build_floor:
		_build_floor()
	if spawn_on_ready:
		spawn()


## Build the configured population. Any creatures this spawner made earlier are removed first, so calling it
## twice replaces the population rather than stacking a second one on top of it.
func spawn() -> void:
	clear()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = placement_seed
	for kind in _ordered_kinds():
		var wanted: int = int(counts[kind])
		for i in range(wanted):
			var creature: Node = _make_creature(String(kind), _scatter_point(rng))
			if creature != null:
				_creatures.append(creature)


## The creatures this spawner made and that are still alive (a starved/eaten one frees itself).
func spawned() -> Array[Node]:
	var out: Array[Node] = []
	for c in _creatures:
		if is_instance_valid(c):
			out.append(c)
	return out


## Remove every creature this spawner made. Leaves the convenience floor in place.
func clear() -> void:
	for c in _creatures:
		if is_instance_valid(c):
			c.queue_free()
	_creatures.clear()


func _make_creature(kind: String, where: Vector3) -> Node:
	var creature: Node = CreatureScene.instantiate()
	# Configure explicitly rather than through standalone_on_ready, so the node is positioned before its
	# terrain adapter and species config are applied (the same order ThinkingCreatureDemo uses).
	creature.standalone_on_ready = false
	add_child(creature)
	if creature is Node3D:
		(creature as Node3D).global_position = where
	creature.llm_enabled = llm_enabled          # setup() keeps this unless the species file overrides it
	var opts: Dictionary = {"ground_y": ground_y}
	if cognition_scheduler != null:
		opts["cognition_scheduler"] = cognition_scheduler
	creature.setup_standalone(kind, opts)
	return creature


func _scatter_point(rng: RandomNumberGenerator) -> Vector3:
	var half: Vector3 = area_extent * 0.5
	var offset: Vector3 = Vector3(
		rng.randf_range(-half.x, half.x),
		rng.randf_range(-half.y, half.y),
		rng.randf_range(-half.z, half.z)
	)
	# X/Z are centred on the spawner; Y starts from the ground plane rather than the spawner's own height, so
	# raising the node in the viewport does not also raise where its creatures are dropped.
	return Vector3(global_position.x + offset.x, ground_y + offset.y, global_position.z + offset.z)


# Sorted so the scatter is reproducible from the seed no matter what order the species rows were typed in.
func _ordered_kinds() -> Array:
	var kinds: Array = counts.keys()
	kinds.sort()
	return kinds


# A plain visible + collidable square floor at ground_y. A StaticBody3D so a thrown rock or a toppled body
# has something to rest on; the creatures themselves snap to ground_y through their flat terrain adapter.
func _build_floor() -> void:
	var body: StaticBody3D = StaticBody3D.new()
	body.name = "SpawnerFloor"
	add_child(body)
	# ground_y is an ABSOLUTE world height — that is how _scatter_point() and the creatures' flat
	# terrain adapter both read it. Setting `position` here would treat it as an offset from the
	# spawner instead, so the floor drifted away from the creatures the moment the spawner was not
	# sitting at world Y 0. Place it in the same space they use.
	body.global_position = Vector3(global_position.x, ground_y, global_position.z)
	var vis: MeshInstance3D = MeshInstance3D.new()
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2(floor_size, floor_size)
	vis.mesh = plane
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = floor_color
	vis.material_override = mat
	body.add_child(vis)
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(floor_size, 0.4, floor_size)
	shape.shape = box
	shape.position = Vector3(0.0, -0.2, 0.0)
	body.add_child(shape)


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if counts.is_empty():
		out.append("Counts is empty, so this spawner will not make anything. Add a row, e.g. \"rabbit\" -> 5.")
	for kind in counts.keys():
		var id: String = String(kind)
		if id.strip_edges() == "":
			out.append("Counts has a blank species id. Name a species, e.g. \"rabbit\".")
			continue
		out.append_array(LocalAgentCreatureWarnings.check_species(id, "Counts key \"%s\"" % id))
		if int(counts[kind]) <= 0:
			out.append("Counts[\"%s\"] is %d, so no %s will be spawned." % [id, int(counts[kind]), id])
	if area_extent.x < 0.0 or area_extent.y < 0.0 or area_extent.z < 0.0:
		out.append("Area Extent has a negative component %s. It is a box size — use 0 or more." % str(area_extent))
	elif area_extent.x <= 0.0 and area_extent.z <= 0.0:
		out.append("Area Extent is flat in X and Z, so every creature will be spawned on the same spot.")
	if llm_enabled and cognition_scheduler == null:
		out.append("Llm Enabled is on but no Cognition Scheduler is assigned here, so these creatures escalate only if something else in the scene gives them one.")
	if cognition_scheduler != null and not llm_enabled:
		out.append("A Cognition Scheduler is assigned but Llm Enabled is off, so no creature will escalate to it.")
	return out


# Property setters call this so the inspector's warning triangle updates as you type, instead of only when
# the node is re-selected. Editor-only: update_configuration_warnings() has nothing to refresh at runtime.
func _refresh_warnings() -> void:
	if Engine.is_editor_hint():
		update_configuration_warnings()
