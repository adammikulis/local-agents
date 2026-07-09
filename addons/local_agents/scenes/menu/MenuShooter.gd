class_name LAMenuShooter
extends Node

## LAMenuShooter — the menu scenes' tiny self-screenshot harness (the front-end analogue of the sim's
## --shoot path). A menu scene adds one as a child; it reads `--shoot=<path> [--shoot-frames=N]` from the
## user command-line args, waits N process frames so the UI has laid out and painted, captures the root
## viewport to a PNG, prints `MENU_SHOT_SAVED=<path>`, and quits. When no --shoot arg is present it does
## nothing, so it is inert in normal interactive play. (Explicit types only — no ':=' inferred typing.)

var _shoot_path: String = ""
var _shoot_frames: int = 20
var _frame: int = 0
var _done: bool = false


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shoot="):
			_shoot_path = arg.substr("--shoot=".length())
		elif arg.begins_with("--shoot-frames="):
			_shoot_frames = maxi(2, int(arg.substr("--shoot-frames=".length())))
	set_process(_shoot_path != "")


func _process(_delta: float) -> void:
	if _done or _shoot_path == "":
		return
	_frame += 1
	if _frame < _shoot_frames:
		return
	_done = true
	var viewport: Viewport = get_viewport()
	if viewport != null:
		var img: Image = viewport.get_texture().get_image()
		var err: int = img.save_png(_shoot_path)
		print("MENU_SHOT_SAVED=%s ok=%s" % [_shoot_path, str(err == OK)])
	LAAppExit.request(self, 0)
