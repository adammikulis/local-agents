extends Node3D

## CORE smoke test — proves the relocated creature/behaviour stack runs with the game deleted. It
## instantiates a core Creature via setup_standalone("rabbit") on a bare Node3D + flat floor, steps it
## headless for a few frames, and prints CORE_SMOKE={...} reporting the creature exists and stands on the
## ground plane. It references ONLY core classes (Creature.tscn + its default LAFlatGroundTerrain adapter,
## LASpeciesLibrary reading creatures/species/) — no MaterialField, no planet, no ecology, no game autoload —
## so it stays runnable after scenes/simulation/voxel/ (the whole game) is removed. This file lives in the
## core library (creatures/smoke/) precisely so it survives that deletion and can be the game-deletable proof.
##
## Run: godot --headless --path . addons/local_agents/creatures/smoke/CoreCreatureSmoke.tscn -- --run-frames=120
## (Explicit types only — project rule: no ':=' inferred typing.)

const CreatureScene: PackedScene = preload("res://addons/local_agents/creatures/Creature.tscn")

@export var species: String = "rabbit"

var _run_frames: int = 60
var _frame: int = 0
var _creature: Node = null
var _spawn_y: float = 2.0


func _ready() -> void:
	_parse_run_frames()
	_build_floor()
	_creature = CreatureScene.instantiate()
	_creature.standalone_on_ready = false          # configure explicitly after positioning
	add_child(_creature)
	if _creature is Node3D:
		(_creature as Node3D).global_position = Vector3(0.0, _spawn_y, 0.0)
	_creature.setup_standalone(species)            # flat-ground terrain + pure fast brain, no field/ecology


func _build_floor() -> void:
	var floor_body: StaticBody3D = StaticBody3D.new()
	floor_body.name = "Floor"
	add_child(floor_body)
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(80.0, 0.4, 80.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.2, 0.0)
	floor_body.add_child(shape)


func _process(_delta: float) -> void:
	_frame += 1
	if _frame < _run_frames:
		return
	set_process(false)
	var exists: bool = is_instance_valid(_creature)
	var y: float = 999.0
	var sp: String = ""
	var stands: bool = false
	if exists and _creature is Node3D:
		y = (_creature as Node3D).global_position.y
		stands = absf(y) < 5.0                      # snapped to the flat ground (y ~ 0), not fallen away
		sp = String(_creature.get("species")) if _creature.get("species") != null else ""
	var ok: bool = exists and stands
	print("CORE_SMOKE={\"ok\":%s,\"exists\":%s,\"stands\":%s,\"species\":\"%s\",\"y\":%.3f,\"frames\":%d}"
		% [str(ok).to_lower(), str(exists).to_lower(), str(stands).to_lower(), sp, y, _frame])
	get_tree().quit(0 if ok else 1)


func _parse_run_frames() -> void:
	for arg in OS.get_cmdline_user_args():
		if String(arg).begins_with("--run-frames="):
			_run_frames = maxi(1, int(String(arg).get_slice("=", 1)))
