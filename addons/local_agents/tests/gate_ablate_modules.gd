extends SceneTree

## A MODULE IS ITS NODE'S WHOLE SUBTREE: off, nothing under it draws or processes; on, each node is as it
## was; a root it shows while off is hidden before a frame is drawn and shown when it returns; one node
## answers to one switch; the test-mass module off holds no probe.


class LateAlways extends Node:
	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS

class Body extends Node3D:
	var _body_basis: Basis = Basis.IDENTITY
	func center() -> Vector3: return Vector3.ZERO
	func angular_velocity_rad_s() -> float: return 0.0
	func spin_axis() -> Vector3: return Vector3.UP

var _fail: int = 0
var _claims: int = 0
var _frames: int = 0
var _module: Node = null
var _layer: CanvasLayer = null
var _rect: ColorRect = null
var _shut: CanvasLayer = null
var _world: Node3D = null
var _mesh: MeshInstance3D = null
var _always: Node = null
var _writer: Node3D = null
var _clock: CanvasLayer = null
var _view: Node3D = null
var _late_always: Node = null
var _late_layer: CanvasLayer = null
var _moved: Node3D = null


func _claim(ok: bool, msg: String) -> void:
	_claims += 1
	if not ok:
		printerr(msg)
		_fail += 1


## Once per frame, from this script's own loop or lint_headless_batch.gd's; true once the verdict is out.
## The first frame switches the module off inside the live tree, whose deferred calls run as that frame
## ends; the second reads what they did.
func _after_frame() -> bool:
	_frames += 1
	if _frames == 1:
		var live: Window = (Engine.get_main_loop() as SceneTree).root
		_build(live)
		_switch_off()
		_late_always = LateAlways.new()
		_late_layer = CanvasLayer.new()
		_module.add_child(_late_always)
		_module.add_child(_late_layer)
		_test_masses(live)
		_one_switch_per_node()
		_moved = Node3D.new()
		_moved.process_mode = Node.PROCESS_MODE_ALWAYS
		live.add_child(_moved)
		LAAblate.adopt("probe_moved", _moved)
		LAAblate.set_on("probe_moved", false)
		_moved.reparent(_module)
		_claim(not LAAblate.names().has("probe_moved") and not _moved.can_process() and not _moved.visible,
			"A reparented module retained a second switch or escaped its new owner.")
		var panels: PackedStringArray = LAAblate.panels()
		_claim(panels.has("probe_module") and panels.has("probe_clock") and not panels.has("probe_view"),
			"LAAblate.panels() reads %s: a module holding a CanvasLayer draws over the frame, one drawing only in the world does not." % [panels])
		return false
	if _frames == 2:
		_claim(not _writer.visible, "A root the module showed while switched off is still drawn.")
		_claim(not _late_always.can_process() and not _late_layer.visible,
			"A descendant added while its module is off escaped processing or visibility ownership.")
		var live: Window = (Engine.get_main_loop() as SceneTree).root
		_late_always.reparent(live)
		_late_layer.reparent(live)
		_always.reparent(_clock)
		LAAblate.set_on("probe_module", true)
		_claim(not _always.can_process(), "Enabling the former owner released a node held by its new module.")
		return false
	_claim(_late_always.can_process() and _late_layer.visible,
		"A descendant reparented out of an off module retained its former hold.")
	_switch_on()
	_claim(_moved.visible and _moved.process_mode == Node.PROCESS_MODE_ALWAYS,
		"A reparented module lost its own state during ownership transfer.")
	_claim(_late_always.process_mode == Node.PROCESS_MODE_ALWAYS and _late_layer.visible,
		"A dynamically added descendant did not regain its intended state.")
	print('ABLATE_MODULES={"claims":%d,"failures":%d}' % [_claims, _fail])
	return true


func _process(_delta: float) -> bool:
	if _after_frame():
		quit(1 if _fail > 0 else 0)
	return false


func _build(live: Window) -> void:
	_module = Node.new()
	_layer = CanvasLayer.new()
	_rect = ColorRect.new()
	_layer.add_child(_rect)
	_shut = CanvasLayer.new()
	_shut.visible = false
	_world = Node3D.new()
	_mesh = MeshInstance3D.new()
	_world.add_child(_mesh)
	_always = Node.new()
	_always.process_mode = Node.PROCESS_MODE_ALWAYS
	_writer = Node3D.new()
	_writer.visible = false
	for n: Node in [_layer, _shut, _world, _always, _writer]:
		_module.add_child(n)
	live.add_child(_module)
	_clock = CanvasLayer.new()
	_clock.process_mode = Node.PROCESS_MODE_ALWAYS
	live.add_child(_clock)
	_view = Node3D.new()
	live.add_child(_view)
	LAAblate.adopt("probe_module", _module)
	LAAblate.adopt("probe_clock", _clock)
	LAAblate.adopt("probe_view", _view)


func _switch_off() -> void:
	LAAblate.set_on("probe_module", false)
	LAAblate.set_on("probe_clock", false)
	_claim(not LAAblate.is_on("probe_module"), "The module reads on with its switch off.")
	_claim(not _layer.visible and not _rect.is_visible_in_tree(),
		"A CanvasLayer under the module's plain Node still draws with the switch off.")
	_claim(not _world.is_visible_in_tree() and not _mesh.is_visible_in_tree(),
		"A 3-D root under the module's plain Node still draws with the switch off.")
	for n: Node in [_module, _layer, _rect, _world, _mesh, _always, _writer]:
		_claim(not n.can_process(), "%s still processes with the module switched off." % n)
	_claim(not _clock.can_process() and not _clock.visible,
		"A module that runs through a pause still runs, or draws, switched off.")
	_writer.visible = true


func _switch_on() -> void:
	LAAblate.set_on("probe_module", true)
	LAAblate.set_on("probe_clock", true)
	_claim(LAAblate.is_on("probe_module"), "The module reads off with its switch on.")
	_claim(_layer.visible and _rect.is_visible_in_tree() and _mesh.is_visible_in_tree(),
		"The module's visuals did not come back with its switch.")
	_claim(not _shut.visible, "A panel hidden by its own design was shown by the switch coming back.")
	_claim(_writer.visible, "A root the module showed while switched off is hidden now the switch is back.")
	_claim(_always.process_mode == Node.PROCESS_MODE_ALWAYS and _module.process_mode == Node.PROCESS_MODE_INHERIT
		and _module.can_process(), "The module came back in process modes other than its own.")
	_claim(_clock.process_mode == Node.PROCESS_MODE_ALWAYS and _clock.visible,
		"A module that runs through a pause came back in process mode %d." % _clock.process_mode)


func _test_masses(live: Window) -> void:
	LAProcessSet.declare(LAProcessSet.GRAVITY)
	var body: Body = Body.new()
	var probes: LATestMasses = LATestMasses.new()
	live.add_child(body)
	live.add_child(probes)
	probes.setup(body, body)
	var at: Vector3 = Vector3(0.0, 100.0, 0.0)
	var id: int = probes.drop_at(at)
	_claim(id >= 0 and not LABallistics.state(id).is_empty(), "The rig released no probe, so its removal asks nothing.")
	LAAblate.adopt("probe_masses", probes)
	LAAblate.set_on("probe_masses", false)
	_claim(LABallistics.state(id).is_empty() and probes.rows().is_empty(),
		"The test-mass module switched off still holds its probe.")
	_claim(probes.drop_at(at) < 0, "The test-mass module switched off released a probe.")
	LAAblate.set_on("probe_masses", true)
	var again: int = probes.drop_at(at)
	_claim(again >= 0, "The test-mass module switched back on releases no probe.")
	LABallistics.release(again)


func _one_switch_per_node() -> void:
	LAAblate.adopt("probe_nested", _world)
	LAAblate.adopt("probe_twice", _view)
	var names: PackedStringArray = LAAblate.names()
	_claim(not names.has("probe_nested") and not names.has("probe_twice"),
		"A node inside another module, or one already switched, took a second switch.")
