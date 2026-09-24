extends Node3D


@onready var _sim: LocalAgentSimWorld = %SimWorld as LocalAgentSimWorld

var _harness_frames: int = 0
var _shot_viewport: SubViewport = null


func demo_harness_configured(frames: int, shoot: String) -> void:
	_harness_frames = frames
	if shoot != "":
		_move_offscreen.call_deferred()


# A photographed run draws into an off-screen SubViewport of --shoot-size; the OS window keeps its one pixel.
func _move_offscreen() -> void:
	_shot_viewport = LocalAgentDemoHarness.offscreen_shot_viewport(self)


## The surface a screenshot is read back from. LocalAgentDemoHarness asks for it by name.
func shot_viewport() -> Viewport:
	return _shot_viewport if _shot_viewport != null else get_viewport()


# The payload LocalAgentDemoHarness prints at the end of a `--run-frames=N` run. Counts come from the
# scene tree groups the ecology puts life into, so they measure the world rather than a private list.
func demo_report() -> Dictionary:
	var kind: String = "SPHERE" if _sim.world_type == LocalAgentSimWorld.WorldType.SPHERE else "FLAT"
	return {
		"world_type": kind,
		"frames": _harness_frames,
		"creatures": get_tree().get_node_count_in_group("creature"),
		"plants": get_tree().get_node_count_in_group("plant"),
		"spawned": _sim.has_spawned(),
	}
