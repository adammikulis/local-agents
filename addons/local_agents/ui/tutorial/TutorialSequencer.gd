class_name LATutorialSequencer
extends Node

## Drives a guided tutorial: walks an ordered list of LATutorialStep resources, resolving each step's
## target to a screen rectangle and feeding an LATutorialHighlightOverlay, then advancing when the step's
## condition is met (Next button, target press, a polled predicate, or an external signal). Supports back,
## skip, and a persisted "don't show again" flag per tutorial id (user:// config). Fully decoupled from any
## particular scene: the caller supplies the step list, the overlay, a target root (for NodePath targets)
## and an optional Camera3D (for world-space targets). (Explicit types only — no ':=' .)

signal tutorial_started
signal step_changed(index: int, step: LATutorialStep)
signal tutorial_finished(completed: bool)   # completed = walked to the end (vs. skipped/quit)

const CONFIG_PATH: String = "user://tutorial_state.cfg"
const CONFIG_SECTION: String = "seen"

var _steps: Array[LATutorialStep] = []
var _overlay: LATutorialHighlightOverlay = null
var _target_root: Node = null
var _camera: Camera3D = null
var _tutorial_id: String = ""
var _index: int = -1
var _active: bool = false
var _dont_show: bool = false

# Per-step advance wiring we must undo when leaving the step.
var _target_control: Control = null
var _connected_target: BaseButton = null
var _connected_signal_source: Object = null
var _connected_signal_name: StringName = &""


func _ready() -> void:
	set_process(false)


## Whether the tutorial with this id should still be shown (false once the player ticked "don't show again").
static func should_show(tutorial_id: String) -> bool:
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return true
	return not bool(cfg.get_value(CONFIG_SECTION, tutorial_id, false))


## Persist (or clear) the "don't show again" flag for a tutorial id.
static func set_dont_show(tutorial_id: String, dont_show: bool) -> void:
	var cfg: ConfigFile = ConfigFile.new()
	cfg.load(CONFIG_PATH)   # ignore missing-file error; we're about to write
	cfg.set_value(CONFIG_SECTION, tutorial_id, dont_show)
	cfg.save(CONFIG_PATH)


## Start walking `steps`. `target_root` is the base for step control paths; `camera` projects world targets.
## `tutorial_id` keys the "don't show again" flag (pass "" to disable persistence). Returns false without
## starting if the id has been dismissed.
func start(steps: Array[LATutorialStep], overlay: LATutorialHighlightOverlay, target_root: Node,
		camera: Camera3D = null, tutorial_id: String = "") -> bool:
	if steps.is_empty() or overlay == null:
		return false
	if tutorial_id != "" and not should_show(tutorial_id):
		return false
	_steps = steps
	_overlay = overlay
	_target_root = target_root if target_root != null else self
	_camera = camera
	_tutorial_id = tutorial_id
	_dont_show = false
	_active = true
	_index = -1

	if not _overlay.next_pressed.is_connected(_on_next):
		_overlay.next_pressed.connect(_on_next)
	if not _overlay.back_pressed.is_connected(_on_back):
		_overlay.back_pressed.connect(_on_back)
	if not _overlay.skip_pressed.is_connected(_on_skip):
		_overlay.skip_pressed.connect(_on_skip)
	if not _overlay.dont_show_toggled.is_connected(_on_dont_show):
		_overlay.dont_show_toggled.connect(_on_dont_show)
	_overlay.set_dont_show_visible(tutorial_id != "")

	tutorial_started.emit()
	_goto(0)
	return true


func is_active() -> bool:
	return _active


func current_index() -> int:
	return _index


func _goto(index: int) -> void:
	if not _active:
		return
	_teardown_step()
	if index < 0 or index >= _steps.size():
		_complete(true)
		return
	_index = index
	var step: LATutorialStep = _steps[_index]
	_resolve_target(step)
	_wire_advance(step)
	_present(step)
	step_changed.emit(_index, step)
	set_process(true)   # poll target rect (moving controls / world points) + predicate advance


func _present(step: LATutorialStep) -> void:
	var res: Dictionary = _target_rect_for(step)
	var next_visible: bool = step.advance == LATutorialStep.Advance.NEXT_BUTTON
	var next_label: String = "Finish" if _index == _steps.size() - 1 else "Next"
	var progress: String = "Step %d of %d" % [_index + 1, _steps.size()]
	_overlay.show_step(res["rect"], res["has"], step.title, step.text, progress,
		_index > 0, next_label, next_visible, _dont_show)


func _process(_delta: float) -> void:
	if not _active or _index < 0 or _index >= _steps.size():
		return
	var step: LATutorialStep = _steps[_index]
	# Keep the spotlight tracking a target that moves (a relaying control, a world point under a moving camera).
	var res: Dictionary = _target_rect_for(step)
	_overlay.update_target(res["rect"], res["has"])
	# Predicate advance is polled here.
	if step.advance == LATutorialStep.Advance.PREDICATE and step.advance_predicate.is_valid():
		if bool(step.advance_predicate.call()):
			_advance()


func _resolve_target(step: LATutorialStep) -> void:
	_target_control = null
	if step.target_kind == LATutorialStep.TargetKind.CONTROL and _target_root != null:
		var n: Node = _target_root.get_node_or_null(step.control_path)
		if n is Control:
			_target_control = n as Control


func _target_rect_for(step: LATutorialStep) -> Dictionary:
	match step.target_kind:
		LATutorialStep.TargetKind.CONTROL:
			if _target_control != null and _target_control.is_visible_in_tree():
				return {"rect": _target_control.get_global_rect().grow(step.target_pad), "has": true}
			return {"rect": Rect2(), "has": false}
		LATutorialStep.TargetKind.RECT:
			return {"rect": step.rect.grow(step.target_pad), "has": true}
		LATutorialStep.TargetKind.WORLD:
			if _camera != null and not _camera.is_position_behind(step.world_point):
				var p: Vector2 = _camera.unproject_position(step.world_point)
				var half: float = 28.0 + step.target_pad
				return {"rect": Rect2(p - Vector2(half, half), Vector2(half * 2.0, half * 2.0)), "has": true}
			return {"rect": Rect2(), "has": false}
		_:
			return {"rect": Rect2(), "has": false}


func _wire_advance(step: LATutorialStep) -> void:
	match step.advance:
		LATutorialStep.Advance.TARGET_PRESSED:
			if _target_control is BaseButton:
				_connected_target = _target_control as BaseButton
				if not _connected_target.pressed.is_connected(_on_target_pressed):
					_connected_target.pressed.connect(_on_target_pressed)
		LATutorialStep.Advance.SIGNAL:
			if step.signal_source != null and step.signal_name != &"" and step.signal_source.has_signal(step.signal_name):
				_connected_signal_source = step.signal_source
				_connected_signal_name = step.signal_name
				_connected_signal_source.connect(step.signal_name, _on_signal_advance)
		_:
			pass


func _teardown_step() -> void:
	if _connected_target != null and _connected_target.pressed.is_connected(_on_target_pressed):
		_connected_target.pressed.disconnect(_on_target_pressed)
	_connected_target = null
	if _connected_signal_source != null and _connected_signal_name != &"":
		if _connected_signal_source.is_connected(_connected_signal_name, _on_signal_advance):
			_connected_signal_source.disconnect(_connected_signal_name, _on_signal_advance)
	_connected_signal_source = null
	_connected_signal_name = &""


func _advance() -> void:
	_goto(_index + 1)


func _on_next() -> void:
	if not _active:
		return
	# Next always advances; for non-Next steps it also acts as a manual override if the button is shown.
	_advance()


func _on_back() -> void:
	if not _active:
		return
	_goto(maxi(0, _index - 1))


func _on_skip() -> void:
	if not _active:
		return
	_complete(false)


func _on_target_pressed() -> void:
	if _active:
		_advance()


func _on_signal_advance(_a = null, _b = null, _c = null, _d = null) -> void:
	# Tolerates signals that carry 0..4 args; we only care that it fired.
	if _active:
		_advance()


func _on_dont_show(enabled: bool) -> void:
	_dont_show = enabled


func _complete(completed: bool) -> void:
	if not _active:
		return
	_teardown_step()
	set_process(false)
	_active = false
	if _tutorial_id != "" and _dont_show:
		set_dont_show(_tutorial_id, true)
	if _overlay != null:
		_overlay.finish()
	tutorial_finished.emit(completed)
	_index = -1
