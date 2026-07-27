extends Node3D

## Library demo — a thinking Creature standing + wandering on a plain FLAT floor, configured entirely by
## Creature.setup_standalone(). This is the CORE showcase: an agent that thinks + walks with NO voxel world.
## It imports NOTHING from the voxel material/ecology/planet/field — only the Creature behaviour prefab (which
## defaults to an LAFlatGroundTerrain adapter) and, optionally, a core LocalAgent as a co-located slow brain.
## The creature runs on its pure fast/reinforced brain against the flat ground; no MaterialField is created.
## (Explicit types only — project rule: no ':=' inferred typing.)

const CreatureScene: PackedScene = preload("res://addons/local_agents/creatures/Creature.tscn")
const LocalAgentScript: GDScript = preload("res://addons/local_agents/agents/Agent.gd")

## A species with a data file ("rabbit", "fox", "bird", …) or "" for the built-in generic walker.
@export var species: String = "rabbit"
@export var creature_count: int = 5
## Opt IN to add a core LocalAgent node as the co-located slow brain (inert with no local model). Off by
## default so the demo boots clean with no LLM server.
@export var wire_local_agent_slow_brain: bool = false

var _run_frames: int = 0
var _frame: int = 0
var _agent = null
var _creatures: Array = []


func _ready() -> void:
	_parse_run_frames()
	_build_floor()
	_build_camera_and_light()
	if wire_local_agent_slow_brain:
		# The core LocalAgent primitive, co-located as the creatures' slow brain. Inert (no model/server) here;
		# a project wires its LLM client into the creatures' cognition scheduler. Kept core — no voxel deps.
		_agent = LocalAgentScript.new()
		_agent.name = "SlowBrain"
		add_child(_agent)
	_spawn_creatures()


# A plain visible + collidable floor at y = 0 (the flat terrain's ground plane). A StaticBody3D so a thrown
# rock / dropped body has something to rest on; the creature itself terrain-snaps to y = 0 via its adapter.
func _build_floor() -> void:
	var floor_body: StaticBody3D = StaticBody3D.new()
	floor_body.name = "Floor"
	add_child(floor_body)
	var vis: MeshInstance3D = MeshInstance3D.new()
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2(80.0, 80.0)
	vis.mesh = plane
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.32, 0.45, 0.28)
	vis.material_override = mat
	floor_body.add_child(vis)
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(80.0, 0.4, 80.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.2, 0.0)
	floor_body.add_child(shape)


func _build_camera_and_light() -> void:
	var light: DirectionalLight3D = DirectionalLight3D.new()
	light.rotation = Vector3(-1.1, 0.6, 0.0)
	add_child(light)
	var cam: Camera3D = Camera3D.new()
	cam.position = Vector3(0.0, 14.0, 24.0)
	cam.rotation = Vector3(-0.5, 0.0, 0.0)
	cam.current = true
	add_child(cam)


func _spawn_creatures() -> void:
	for i in range(creature_count):
		var creature: Node = CreatureScene.instantiate()
		# Configure explicitly (not via standalone_on_ready) so we can set position first.
		creature.standalone_on_ready = false
		add_child(creature)
		if creature is Node3D:
			(creature as Node3D).global_position = Vector3(randf_range(-8.0, 8.0), 2.0, randf_range(-8.0, 8.0))
		creature.setup_standalone(species)          # pure fast brain; flat-ground terrain; no field/ecology
		_creatures.append(creature)


func _process(_delta: float) -> void:
	if _run_frames <= 0:
		return
	_frame += 1
	if _frame == _run_frames:
		var alive: int = 0
		var moved: int = 0
		for c in _creatures:
			if is_instance_valid(c) and c is Node3D:
				alive += 1
				if absf((c as Node3D).global_position.y) < 5.0:
					moved += 1
		print("THINKING_CREATURE_REPORT={\"frames\":%d,\"creatures\":%d,\"on_floor\":%d,\"species\":\"%s\"}"
			% [_frame, alive, moved, species])
		LAAppExit.request(self, 0)


func _parse_run_frames() -> void:
	for arg in OS.get_cmdline_user_args():
		if String(arg).begins_with("--run-frames="):
			_run_frames = maxi(0, int(String(arg).get_slice("=", 1)))
