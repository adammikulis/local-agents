extends Node3D


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
