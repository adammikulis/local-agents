extends Node3D


@onready var _spawner: LocalAgentCreatureSpawner = %Spawner as LocalAgentCreatureSpawner

var _harness_frames: int = 0


# LocalAgentDemoHarness hands back the resolved command line, so the report can quote the frame budget
# it was actually given without this scene re-reading argv.
func demo_harness_configured(frames: int, _shoot: String) -> void:
	_harness_frames = frames


func demo_report() -> Dictionary:
	var alive: Array[Node] = _spawner.spawned()
	var on_floor: int = 0
	for c in alive:
		if c is Node3D and absf((c as Node3D).global_position.y - _spawner.ground_y) < 5.0:
			on_floor += 1
	return {
		"frames": _harness_frames,
		"creatures": alive.size(),
		"on_floor": on_floor,
		"species": _species_label(),
	}


# The species this run actually asked for, read back off the spawner rather than duplicated here, so
# editing the Counts dictionary in the inspector also moves the report.
func _species_label() -> String:
	var kinds: Array = _spawner.counts.keys()
	kinds.sort()
	var names: PackedStringArray = PackedStringArray()
	for k in kinds:
		names.append(String(k))
	return "+".join(names)
