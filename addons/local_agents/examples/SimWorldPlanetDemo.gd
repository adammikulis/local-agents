extends Node3D

## A whole cubed-sphere planet with a living ecology, and no game shell at all: no HUD, menus,
## disasters, save system or streamer.
##
## The scene is the demo. There is no world-building code here at all:
##   - SimWorld (LocalAgentSimWorld) is the entire planet. World Type, Radius, the field grid, the
##     founding Initial Counts and the forest clusters are inspector properties on that one node. It
##     composes the planet body, the MaterialField shell, its own Sun and the ecology behind them.
##     Switch World Type to Flat and the same node builds a ground plane, needing no godot_voxel.
##   - Camera3D frames the planet (Far is raised to see past it). DirectionalLight3D lights the view.
##     SimWorld also builds its own child Sun, which is the light the field's solar pass is driven
##     by. That one is simulation. This one is presentation.
##   - DemoHarness gives the scene `-- --run-frames=N`, which prints SIM_WORLD_REPORT and quits. It lives
##     on the demo, not inside LocalAgentSimWorld: a reusable library node has no business owning a
##     process exit.
##
## What is left here is the one thing a game author would actually write: what the run should measure.
## (Explicit types only. The project rule bans ':=' inferred typing.)

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
