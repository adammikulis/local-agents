extends Node3D

## CORE smoke test — proves the creature/behaviour stack runs with the game deleted. This is a PASS/FAIL
## gate, not a showcase: it exits NON-ZERO when the creature is missing or has fallen off the ground
## plane, so CI notices.
##
## THE SCENE IS THE TEST, and it is deliberately the simplest thing that can work — the drop-in path a
## library user takes first:
##   - Creature is a plain Creature.tscn INSTANCE, dragged in and dropped 2 m above the floor, with
##     Standalone Species set to "rabbit" in the inspector. Nothing configures it; Creature.tscn ships
##     with Standalone On Ready ticked, so it reads its species file, attaches a flat-ground terrain
##     adapter at Ground Y and starts running its fast brain by itself. That "it just works" is exactly
##     what this smoke exists to check.
##   - Floor is an ordinary StaticBody3D so a dropped body has something to rest on.
##   - DemoHarness owns the run: Run Frames 60, and a bare CORE_SMOKE={...} marker (Report Suffix is
##     cleared) because that is the marker this scene has always printed. `-- --run-frames=N` overrides.
##
## It references ONLY core classes — no MaterialField, no planet, no ecology, no game autoload — so it
## stays runnable after the whole voxel game is removed.
##
## Run: godot --headless --path . addons/local_agents/examples/CoreCreatureSmoke.tscn -- --run-frames=120
## (Explicit types only — project rule: no ':=' inferred typing.)

## How far the creature may sit from the ground plane and still count as standing. Generous on purpose:
## the test is "did it snap to the floor", not "did it hold a pose".
const STAND_TOLERANCE_M: float = 5.0

@onready var _creature: LocalAgentCreature = %Creature as LocalAgentCreature

var _harness_frames: int = 0


func demo_harness_configured(frames: int, _shoot: String) -> void:
	_harness_frames = frames


# Built as a string rather than a Dictionary because `y` reads as three fixed decimals here, which JSON's
# float formatting will not give us.
func demo_report_json() -> String:
	var exists: bool = is_instance_valid(_creature)
	var y: float = 999.0
	var sp: String = ""
	var stands: bool = false
	if exists:
		y = _creature.global_position.y
		stands = _stands()
		sp = _creature.species
	return ("{\"ok\":%s,\"exists\":%s,\"stands\":%s,\"species\":\"%s\",\"y\":%.3f,\"frames\":%d}"
		% [str(exists and stands).to_lower(), str(exists).to_lower(), str(stands).to_lower(), sp, y, _harness_frames])


# A smoke test is only useful if it can fail the build: non-zero unless the creature exists and stands.
func demo_exit_code() -> int:
	return 0 if (is_instance_valid(_creature) and _stands()) else 1


# Snapped to the flat ground (y ~ Ground Y), not fallen away through it.
func _stands() -> bool:
	if not is_instance_valid(_creature):
		return false
	return absf(_creature.global_position.y - _creature.ground_y) < STAND_TOLERANCE_M
