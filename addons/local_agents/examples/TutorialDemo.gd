extends Control


@export var steps: Array[LocalAgentTutorialStep] = []

## Keys the "don't show again" flag the sequencer persists to user://. Blank hides that checkbox.
@export var tutorial_id: String = "demo_tutorial"

@export_group("Headless auto-drive")
## Frames the spotlight is left resting on a button before the headless auto-driver presses it.
## Interactive runs never use this. `--run-frames` is what arms the driver.
@export_range(0, 240, 1, "suffix:frames") var press_cooldown_frames: int = 6

@onready var _overlay: LATutorialHighlightOverlay = %HighlightOverlay
@onready var _sequencer: LATutorialSequencer = %TutorialSequencer
@onready var _buttons: VBoxContainer = %Buttons
@onready var _log: Label = %PressLog

var _auto: bool = false
var _auto_cooldown: int = 0
var _harness_frames: int = 0
var _finished: bool = false


func _ready() -> void:
	for child in _buttons.get_children():
		if child is BaseButton:
			(child as BaseButton).pressed.connect(_on_demo_button.bind(child.name))
	_sequencer.step_changed.connect(_on_step_changed)
	_sequencer.tutorial_finished.connect(_on_finished)
	# Control paths in the steps are relative to this node, which is why `self` is the target root.
	# No camera: every step here points at a Control, not a world position.
	_sequencer.start(steps, _overlay, self, null, tutorial_id)


func _on_demo_button(which: StringName) -> void:
	_log.text = "You pressed: %s" % String(which)


func _on_step_changed(index: int, _step: LocalAgentTutorialStep) -> void:
	print("TUTORIAL_STEP=%d" % index)
	_auto_cooldown = press_cooldown_frames


func _on_finished(completed: bool) -> void:
	_finished = true
	print("TUTORIAL_DONE=%s" % ("true" if completed else "false"))
	_log.text = "Tutorial finished."


## Called once by LocalAgentDemoHarness with the resolved command line.
func demo_harness_configured(frames: int, _shoot: String) -> void:
	_harness_frames = frames
	_auto = frames > 0
	set_process(_auto)


func _process(_delta: float) -> void:
	if not _auto or _finished or not _sequencer.is_active():
		return
	if _auto_cooldown > 0:
		_auto_cooldown -= 1
		return
	var target: BaseButton = _current_step_button()
	if target != null:
		target.pressed.emit()
		_auto_cooldown = press_cooldown_frames


# The step already names its target, so the driver reads it back rather than keeping a second list.
func _current_step_button() -> BaseButton:
	var index: int = _sequencer.current_index()
	if index < 0 or index >= steps.size():
		return null
	return get_node_or_null(steps[index].control_path) as BaseButton


## The payload LocalAgentDemoHarness prints at the end of a `--run-frames=N` run.
func demo_report() -> Dictionary:
	return {
		"fps": Performance.get_monitor(Performance.TIME_FPS),
		"frames": _harness_frames,
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"tutorial_finished": _finished,
	}


## Appended to the harness's SHOT_SAVED line, so a screenshot records which step it caught.
func demo_shot_info() -> String:
	return "step=%d" % _sequencer.current_index()
