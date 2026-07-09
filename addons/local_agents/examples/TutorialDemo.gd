extends Control

## Standalone demo + usage example for the reusable tutorial system (LATutorialSequencer +
## LATutorialHighlightOverlay + LATutorialStep). Builds four demo buttons and a three-step guided tour
## that spotlights three of them in turn ("click this", "now this"), verifiable WITHOUT the voxel sim.
##
## Self-harness (matches the repo's convention):
##   -- --shoot=<png> [--shoot-frames=N]   capture a screenshot at frame N (tutorial resting on step 1,
##                                          so the shot shows the spotlight + callout on a button), then quit.
##   -- --run-frames=N                      auto-drive: programmatically press each spotlighted button to
##                                          walk the tutorial to the end, print TUTORIAL_STEP / TUTORIAL_DONE
##                                          and a DEMO_REPORT, then quit (proves advance-on-click wiring).
## (Explicit types only — no ':=' .)

const OverlayScript: GDScript = preload("res://addons/local_agents/ui/tutorial/TutorialHighlightOverlay.gd")
const SequencerScript: GDScript = preload("res://addons/local_agents/ui/tutorial/TutorialSequencer.gd")
const StepScript: GDScript = preload("res://addons/local_agents/ui/tutorial/TutorialStep.gd")

var _overlay: LATutorialHighlightOverlay = null
var _seq: LATutorialSequencer = null
var _buttons: Dictionary = {}          # name -> Button
var _step_targets: Array[Button] = []  # target button per tutorial step (for auto-drive), null if none
var _log: Label = null

# Harness state.
var _shoot_path: String = ""
var _shoot_frames: int = 90
var _run_frames: int = 0
var _frame: int = 0
var _auto: bool = false
var _auto_cooldown: int = 0
var _finished: bool = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_parse_args()
	_build_background()
	_build_buttons()
	_overlay = OverlayScript.new()
	add_child(_overlay)
	_seq = SequencerScript.new()
	add_child(_seq)
	_seq.step_changed.connect(_on_step_changed)
	_seq.tutorial_finished.connect(_on_finished)
	_start_tutorial()
	if _run_frames > 0 or _shoot_path != "":
		set_process(true)


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shoot="):
			_shoot_path = arg.substr("--shoot=".length())
		elif arg.begins_with("--shoot-frames="):
			_shoot_frames = int(arg.substr("--shoot-frames=".length()))
		elif arg.begins_with("--run-frames="):
			_run_frames = int(arg.substr("--run-frames=".length()))
			_auto = true


func _build_background() -> void:
	var bg: ColorRect = ColorRect.new()
	bg.color = Color(0.16, 0.18, 0.22)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var heading: Label = Label.new()
	heading.text = "Tutorial system demo"
	heading.add_theme_font_size_override("font_size", 24)
	heading.position = Vector2(40, 30)
	add_child(heading)

	var sub: Label = Label.new()
	sub.text = "Follow the highlighted callout — it walks you through these buttons in turn."
	sub.add_theme_color_override("font_color", Color(0.7, 0.74, 0.8))
	sub.position = Vector2(40, 64)
	add_child(sub)

	_log = Label.new()
	_log.add_theme_color_override("font_color", Color(0.55, 0.85, 0.6))
	_log.position = Vector2(40, 96)
	add_child(_log)


func _build_buttons() -> void:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.add_theme_constant_override("separation", 18)
	panel.position = Vector2(80, 180)
	panel.name = "Buttons"
	add_child(panel)

	var defs: Array = [
		["Spawn", "Spawn a creature"],
		["Grow", "Grow the world"],
		["Reset", "Reset everything"],
		["Help", "Open help (not part of the tour)"],
	]
	for d in defs:
		var b: Button = Button.new()
		b.text = String(d[1])
		b.name = String(d[0])
		b.custom_minimum_size = Vector2(240, 48)
		b.add_theme_font_size_override("font_size", 18)
		b.pressed.connect(_on_demo_button.bind(String(d[0])))
		panel.add_child(b)
		_buttons[String(d[0])] = b


func _on_demo_button(which: String) -> void:
	if _log != null:
		_log.text = "You pressed: %s" % which


func _start_tutorial() -> void:
	var steps: Array[LATutorialStep] = []
	var s1: LATutorialStep = StepScript.for_control(NodePath("Buttons/Spawn"),
		"This is the Spawn button. Give it a click to add a creature.", "Step 1: Spawn")
	var s2: LATutorialStep = StepScript.for_control(NodePath("Buttons/Grow"),
		"Nice. Now click Grow to expand the world.", "Step 2: Grow")
	var s3: LATutorialStep = StepScript.for_control(NodePath("Buttons/Reset"),
		"Last one — click Reset to finish the tour.", "Step 3: Reset")
	steps.append(s1)
	steps.append(s2)
	steps.append(s3)
	# Target root for the CONTROL paths is this scene root; no camera needed (pure 2D demo).
	_seq.start(steps, _overlay, self, null, "demo_tutorial")

	# Cache the target button per step so the auto-driver can programmatically press them.
	_step_targets = []
	_step_targets.append(_buttons.get("Spawn", null))
	_step_targets.append(_buttons.get("Grow", null))
	_step_targets.append(_buttons.get("Reset", null))


func _on_step_changed(index: int, _step: LATutorialStep) -> void:
	print("TUTORIAL_STEP=%d" % index)
	_auto_cooldown = 24   # let the spotlight settle before the auto-driver presses


func _on_finished(completed: bool) -> void:
	_finished = true
	print("TUTORIAL_DONE=%s" % ("true" if completed else "false"))
	if _log != null:
		_log.text = "Tutorial finished."


func _process(_delta: float) -> void:
	_frame += 1

	# Screenshot mode: sit on the first spotlight step and capture, so the shot shows spotlight + callout.
	if _shoot_path != "" and _frame == _shoot_frames:
		_capture(_shoot_path)
		get_tree().quit(0)
		return

	# Auto-drive mode: press the current step's target button to advance (proves TARGET_PRESSED wiring).
	if _auto and not _finished:
		if _auto_cooldown > 0:
			_auto_cooldown -= 1
		elif _seq.is_active():
			var idx: int = _seq.current_index()
			if idx >= 0 and idx < _step_targets.size() and _step_targets[idx] != null:
				(_step_targets[idx] as Button).pressed.emit()
				_auto_cooldown = 24

	if _run_frames > 0 and _frame >= _run_frames:
		var report: Dictionary = {
			"frames": _frame,
			"tutorial_finished": _finished,
			"fps": Performance.get_monitor(Performance.TIME_FPS),
			"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		}
		print("DEMO_REPORT=%s" % JSON.stringify(report))
		get_tree().quit(0)


func _capture(path: String) -> void:
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(path)
	print("SHOT_SAVED=%s size=%dx%d step=%d" % [path, img.get_width(), img.get_height(), _seq.current_index()])
