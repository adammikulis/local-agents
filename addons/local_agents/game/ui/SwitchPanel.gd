class_name LASwitchPanel
extends VBoxContainer

## EVERY SWITCH THIS RUN HAS, in one list: the physics processes the rung contains, in ladder order,
## then the presentation modules a layer adopted. Generated from LAAblate.names(), so a process the rung
## lacks has no switch and adding one to the ladder adds a row here.

const REFRESH_S: float = 0.5
const SHORTCUT_LABEL: String = "Ctrl+%d"
const SHORTCUT_KEYS: Array = [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9]

var _boxes: Dictionary = {}                              # switch name -> CheckButton
var _order: PackedStringArray = PackedStringArray()
var _suppress: bool = false


func _ready() -> void:
	build()
	var timer: Timer = Timer.new()
	timer.wait_time = REFRESH_S
	timer.timeout.connect(refresh)
	add_child(timer)
	timer.start()


func build() -> void:
	for child in get_children():
		child.queue_free()
	_boxes = {}
	add_theme_constant_override("separation", 2)
	var title: Label = Label.new()
	title.text = "Switches"
	add_child(title)
	_order = LAAblate.names()
	var group: String = ""
	for i in _order.size():
		var name: String = _order[i]
		var entry: Dictionary = LAProcessSet.process_entry(name)
		var head: String = LAProcessSet.name_of(int(entry["rung"])) if not entry.is_empty() else "modules"
		if head != group:
			group = head
			var label: Label = Label.new()
			label.text = head
			add_child(label)
		var cb: CheckButton = CheckButton.new()
		cb.text = name if i >= SHORTCUT_KEYS.size() else "%s   %s" % [name, SHORTCUT_LABEL % (i + 1)]
		cb.tooltip_text = _tooltip(entry)
		cb.toggled.connect(_on_toggled.bind(name))
		add_child(cb)
		_boxes[name] = cb
	refresh()
	print("SWITCH_PANEL=", JSON.stringify({"switches": _order.size(),
		"processes": LAProcessSet.process_names().size()}))


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


func refresh() -> void:
	_suppress = true
	for name in _boxes:
		(_boxes[name] as CheckButton).set_pressed_no_signal(LAAblate.is_on(String(name)))
	_suppress = false


func _on_toggled(on: bool, name: String) -> void:
	if _suppress:
		return
	LAAblate.set_on(name, on)
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
