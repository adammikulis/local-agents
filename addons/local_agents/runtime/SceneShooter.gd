class_name LASceneShooter
extends Node

## Photograph a Control scene: drop one under any scene root and `--shoot=<png>` saves it after
## `--shoot-frames` frames and quits. Nothing appears on a monitor; the picture is a SubViewport's.


var _shoot_path: String = ""
var _shoot_frames: int = 20
var _frame: int = 0
var _done: bool = false
var _viewport: SubViewport = null


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(LocalAgentDemoHarness.ARG_SHOOT_FRAMES):
			_shoot_frames = maxi(2, int(arg.substr(LocalAgentDemoHarness.ARG_SHOOT_FRAMES.length())))
		elif arg.begins_with(LocalAgentDemoHarness.ARG_SHOOT):
			_shoot_path = arg.substr(LocalAgentDemoHarness.ARG_SHOOT.length())
	set_process(_shoot_path != "")
	if _shoot_path == "":
		return
	# The scene draws into an off-screen surface of --shoot-size; the OS window keeps its one pixel.
	_move_offscreen.call_deferred()


func _move_offscreen() -> void:
	_viewport = LocalAgentDemoHarness.offscreen_shot_viewport(get_tree().current_scene)


func _process(_delta: float) -> void:
	if _done or _shoot_path == "":
		return
	_frame += 1
	if _frame < _shoot_frames:
		return
	_done = true
	LocalAgentDemoHarness.save_viewport_png(_viewport, _shoot_path)
	LAAppQuit.request(self, 0)
