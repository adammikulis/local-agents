extends Node3D

## CORE smoke test — proves the relocated creature/behaviour stack runs with the game deleted. It
## instantiates a core Creature via setup_standalone("rabbit") on a bare Node3D + flat floor, steps it
## headless for a few frames, and prints CORE_SMOKE={...} reporting the creature exists and stands on the
## ground plane. It references ONLY core classes (Creature.tscn + its default LAFlatGroundTerrain adapter,
## LASpeciesLibrary reading creatures/species/) — no MaterialField, no planet, no ecology, no game autoload —
## so it stays runnable after scenes/simulation/voxel/ (the whole game) is removed. This file lives in the
## core library (creatures/smoke/) precisely so it survives that deletion and can be the game-deletable proof.
##
## Run: godot --headless --path . addons/local_agents/examples/CoreCreatureSmoke.tscn -- --run-frames=120
## (Explicit types only — project rule: no ':=' inferred typing.)

const CreatureScene: PackedScene = preload("res://addons/local_agents/creatures/Creature.tscn")

## Species data file to instantiate, e.g. "rabbit", "fox", "bird", "mouse", "villager", "fish".
## Backed by creatures/species/**/<id>.json — drop a JSON file there and its id works here.
## Blank uses the built-in generic walker.
## (Left a plain String on purpose: @export_enum cannot offer an empty option, so it could not
## express the generic walker. The editor plugin supplies the dropdown instead.)
@export var species: String = "rabbit"
## Frames to step before printing CORE_SMOKE and quitting. `-- --run-frames=N` overrides it.
@export_range(1, 100000, 1, "suffix:frames") var smoke_frames: int = 60

var _harness_frames: int = 60
var _creature: Node = null
var _spawn_y: float = 2.0


func _ready() -> void:
	_build_floor()
	_creature = CreatureScene.instantiate()
	_creature.standalone_on_ready = false          # configure explicitly after positioning
	add_child(_creature)
	if _creature is Node3D:
		(_creature as Node3D).global_position = Vector3(0.0, _spawn_y, 0.0)
	_creature.setup_standalone(species)            # flat-ground terrain + pure fast brain, no field/ecology
	_add_harness()


# The shared headless harness. Prints a bare CORE_SMOKE={...} with no "_REPORT" suffix, because that
# is the marker this scene has always printed and saved logs are easier to compare if it stays put.
# Exits non-zero when the creature failed to stand.
func _add_harness() -> void:
	var harness: LocalAgentDemoHarness = LocalAgentDemoHarness.new()
	harness.name = "DemoHarness"
	harness.report_prefix = "CORE_SMOKE"
	harness.report_suffix = ""
	harness.run_frames = smoke_frames
	harness.report_source = self
	add_child(harness)


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


func demo_harness_configured(frames: int, _shoot: String) -> void:
	_harness_frames = frames


# Built as a string rather than a Dictionary because `y` reads as three fixed decimals here, which JSON's
# float formatting will not give us.
func demo_report_json() -> String:
	var exists: bool = is_instance_valid(_creature)
	var y: float = 999.0
	var sp: String = ""
	var stands: bool = false
	if exists and _creature is Node3D:
		y = (_creature as Node3D).global_position.y
		stands = absf(y) < 5.0                      # snapped to the flat ground (y ~ 0), not fallen away
		sp = String(_creature.get("species")) if _creature.get("species") != null else ""
	return ("{\"ok\":%s,\"exists\":%s,\"stands\":%s,\"species\":\"%s\",\"y\":%.3f,\"frames\":%d}"
		% [str(exists and stands).to_lower(), str(exists).to_lower(), str(stands).to_lower(), sp, y, _harness_frames])


# A smoke test is only useful if it can fail the build: non-zero unless the creature exists and stands.
func demo_exit_code() -> int:
	var exists: bool = is_instance_valid(_creature)
	var stands: bool = exists and _creature is Node3D and absf((_creature as Node3D).global_position.y) < 5.0
	return 0 if (exists and stands) else 1
