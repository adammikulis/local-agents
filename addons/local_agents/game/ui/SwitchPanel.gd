class_name LASwitchPanel
extends VBoxContainer

## EVERY SWITCH THIS RUN HAS, from LAAblate.names(): the rung's processes in ladder order, the modules a
## layer adopted, then LAFakes' stand-ins. A process and a module read on/off; a stand-in reads off,
## fake or real, so a rung the world lacks has no switch and a landed one adds a row.

const SWITCH: String = "switches"        # this panel's own, never listed: it could not switch itself back on
const REFRESH_S: float = 0.5
const SHORTCUT_LABEL: String = "Ctrl+%d"
const SHORTCUT_KEYS: Array = [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9]

var _boxes: Dictionary = {}                              # switch name -> CheckButton or OptionButton
var _order: PackedStringArray = PackedStringArray()
var _suppress: bool = false


func _ready() -> void:
	build()
	var timer: Timer = Timer.new()
	timer.wait_time = REFRESH_S
	timer.timeout.connect(refresh)
	add_child(timer)
	timer.start()


## The control this switch is thrown with, or null when the run holds no switch of that name.
func control_of(name: String) -> Control:
	return _boxes.get(name, null) as Control


func build() -> void:
	for child in get_children():
		child.queue_free()
	_boxes = {}
	add_theme_constant_override("separation", 2)
	var title: Label = Label.new()
	title.text = "Switches"
	add_child(title)
	LAFakes.states()                                     # the stand-ins take their place on the registry
	_order = LAAblate.names()
	if _order.has(SWITCH):
		_order.remove_at(_order.find(SWITCH))
	var group: String = ""
	for i in _order.size():
		var name: String = _order[i]
		var entry: Dictionary = LAProcessSet.process_entry(name)
		var head: String = "modules"
		if not entry.is_empty():
			head = LAProcessSet.name_of(int(entry["rung"]))
		elif _is_fake(name):
			head = "stand-ins"
		if head != group:
			group = head
			var label: Label = Label.new()
			label.text = head
			add_child(label)
		if _is_fake(name):
			add_child(_fake_row(name))
			continue
		var cb: CheckButton = CheckButton.new()
		cb.text = name if i >= SHORTCUT_KEYS.size() else "%s   %s" % [name, SHORTCUT_LABEL % (i + 1)]
		cb.tooltip_text = _tooltip(entry)
		cb.toggled.connect(_on_toggled.bind(name))
		add_child(cb)
		_boxes[name] = cb
	refresh()
	print("SWITCH_PANEL=", JSON.stringify({"switches": _order.size(),
		"processes": LAProcessSet.process_names().size(), "fakes": LAFakes.states().size()}))


## Only a stand-in has a default state; a process and a module answer on or off.
func _is_fake(name: String) -> bool:
	return LAAblate.default_state(name) != ""


## The declared record behind one stand-in's name.
func _record(name: String) -> Dictionary:
	for r in LAFakes.RECORDS:
		if String(r["name"]) == name:
			return r
	return {}


## One stand-in: what it stands in for, the rung that makes it real, and its three states.
func _fake_row(name: String) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	var label: Label = Label.new()
	var rung: int = LAAblate.fake_rung(name)
	var record: Dictionary = _record(name)
	var when: String = LAProcessSet.name_of(rung) if rung >= 0 else String(record.get("release", ""))
	label.text = "%s   real at %s, default %s" % [name, when, LAAblate.default_state(name)]
	label.tooltip_text = String(record.get("stands_in", ""))
	row.add_child(label)
	var opt: OptionButton = OptionButton.new()
	opt.add_item(LAAblate.state_off())
	opt.add_item(LAAblate.state_fake())
	opt.add_item(LAAblate.state_real())
	opt.item_selected.connect(_on_state_picked.bind(name))
	row.add_child(opt)
	_boxes[name] = opt
	return row


## What a switch turns off, and — where this world transports nothing — that its field's matter cannot
## move whatever the switch says.
func _tooltip(entry: Dictionary) -> String:
	if entry.is_empty():
		return "A presentation module: off means it does not process, time or draw."
	var out: String = "%s \"%s\", declared at the %s rung." % [String(entry["kind"]),
		String(entry["label"]), LAProcessSet.name_of(int(entry["rung"]))]
	if LAProcessSet.transport_rows().is_empty():
		out += "  The field's matter moves at the %s rung, which this world is below." \
			% LAProcessSet.name_of(LAProcessSet.ACOUSTIC)
	return out


func _states() -> PackedStringArray:
	return PackedStringArray([LAAblate.state_off(), LAAblate.state_fake(), LAAblate.state_real()])


func refresh() -> void:
	_suppress = true
	for name in _boxes:
		var control: Control = _boxes[name] as Control
		if control is OptionButton:
			var at: int = _states().find(LAAblate.state_of(String(name)))
			(control as OptionButton).select(at)
			continue
		(control as CheckButton).set_pressed_no_signal(LAAblate.is_on(String(name)))
	_suppress = false


func _on_toggled(on: bool, name: String) -> void:
	if _suppress:
		return
	LAAblate.set_on(name, on)
	refresh()


func _on_state_picked(index: int, name: String) -> void:
	if _suppress:
		return
	var states: PackedStringArray = _states()
	if index < 0 or index >= states.size():
		return
	LAAblate.set_state(name, states[index])
	refresh()


func _unhandled_key_input(event: InputEvent) -> void:
	var key: InputEventKey = event as InputEventKey
	if key == null or not key.pressed or key.echo or not key.ctrl_pressed:
		return
	var i: int = SHORTCUT_KEYS.find(key.keycode)
	if i < 0 or i >= _order.size():
		return
	var name: String = _order[i]
	LAAblate.set_on(name, not LAAblate.is_on(name))
	refresh()
	get_viewport().set_input_as_handled()
