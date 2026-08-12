extends Node3D


@onready var _sim: LocalAgentSimWorld = %SimWorld as LocalAgentSimWorld

var _harness_frames: int = 0


func demo_harness_configured(frames: int, _shoot: String) -> void:
	_harness_frames = frames


# The payload LocalAgentDemoHarness prints at the end of a `--run-frames=N` run. Counts come from the
# scene tree groups the ecology puts life into, so they measure the world rather than a private list.
func demo_report() -> Dictionary:
	var kind: String = "SPHERE" if _sim.world_type == LocalAgentSimWorld.WorldType.SPHERE else "FLAT"
	return {
		"world_type": kind,
		"frames": _harness_frames,
		"creatures": get_tree().get_nodes_in_group("creature").size(),
		"plants": get_tree().get_nodes_in_group("plant").size(),
		"spawned": _sim.has_spawned(),
	}
