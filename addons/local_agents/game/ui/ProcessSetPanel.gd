class_name LAProcessSetPanel
extends VBoxContainer

## The rung selector and, under Custom, one control per process record. Every entry is generated from
## LAProcessSet.records(); nothing here keeps a list of processes of its own.

## A change reseeds the world. Matter and energy are never added to or removed from a sealed one.
const APPLY_NOTE: String = "Applies on restart. A sealed world never gains or loses a process."

signal changed()

var _settings: LAGameSettings = null
var _rung_group: ButtonGroup = null
var _rung_buttons: Dictionary = {}      # rung -> Button
var _custom_button: Button = null
var _boxes: Dictionary = {}             # record id -> CheckBox
var _custom_box: VBoxContainer = null
var _caption: Label = null
var _suppress: bool = false


## `restart` adds the button that reseeds the world; a launcher has no world yet and passes false.
func build(settings: LAGameSettings, restart: bool) -> void:
	_settings = settings
	add_theme_constant_override("separation", 6)
	var title: Label = Label.new()
	title.text = "Physics processes"
	add_child(title)

	_rung_group = ButtonGroup.new()
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	add_child(row)
	var green: int = LAProcessSet.playable()
	for r: Dictionary in LAProcessSet.rungs():
		var at: int = int(r["rung"])
		var b: Button = Button.new()
		b.toggle_mode = true
		b.button_group = _rung_group
		b.text = String(r["name"]) + (" *" if at == green else "")
		b.tooltip_text = "Everything up to and including \"%s\".%s" % [String(r["name"]),
			"  The highest rung the ladder reports green." if at == green else ""]
		b.pressed.connect(_on_rung.bind(at))
		row.add_child(b)
		_rung_buttons[at] = b
	_custom_button = Button.new()
	_custom_button.toggle_mode = true
	_custom_button.button_group = _rung_group
	_custom_button.text = "custom"
	_custom_button.tooltip_text = "Choose the processes one by one."
	_custom_button.pressed.connect(_on_custom)
	row.add_child(_custom_button)

	_caption = Label.new()
	_caption.text = APPLY_NOTE
	add_child(_caption)

	_custom_box = VBoxContainer.new()
	_custom_box.visible = false
	add_child(_custom_box)
	var last: int = -1
	for rec: Dictionary in LAProcessSet.records():
		if int(rec["rung"]) != last:
			last = int(rec["rung"])
			var head: Label = Label.new()
			head.text = LAProcessSet.name_of(last)
			_custom_box.add_child(head)
		var cb: CheckBox = CheckBox.new()
		cb.text = "%s (%s)" % [String(rec["label"]), String(rec["kind"])]
		cb.toggled.connect(_on_box)
		_custom_box.add_child(cb)
		_boxes[LAProcessSet.record_id(rec)] = cb

	if restart:
		var btn: Button = Button.new()
		btn.text = "Restart with these processes"
		btn.pressed.connect(_on_restart)
		add_child(btn)
	refresh()


## The record ids this panel is showing, whatever mode it is in. One entry per enabled record.
func selection() -> PackedStringArray:
	if not _settings.process_records.is_empty():
		return _settings.process_records
	return LAProcessSet.records_upto(_rung())


func refresh() -> void:
	_suppress = true
	var custom: bool = not _settings.process_records.is_empty()
	if _custom_button != null:
		_custom_button.set_pressed_no_signal(custom)
	for at in _rung_buttons:
		(_rung_buttons[at] as Button).set_pressed_no_signal(not custom and int(at) == _rung())
	if _custom_box != null:
		_custom_box.visible = custom
	var on: PackedStringArray = selection()
	for id in _boxes:
		(_boxes[id] as CheckBox).set_pressed_no_signal(on.has(String(id)))
	_suppress = false


func _rung() -> int:
	return LAProcessSet.resolve(_settings.process_rung)


func _on_rung(at: int) -> void:
	if _suppress:
		return
	_settings.process_rung = at
	_settings.process_records = PackedStringArray()
	refresh()
	changed.emit()


func _on_custom(_pressed: bool = true) -> void:
	if _suppress:
		return
	# Entering Custom starts from what the world already contains, so nothing changes until a box does.
	_settings.process_records = LAProcessSet.records_upto(_rung())
	refresh()
	changed.emit()


func _on_box(_on: bool) -> void:
	if _suppress:
		return
	var out: PackedStringArray = PackedStringArray()
	for id in _boxes:
		if (_boxes[id] as CheckBox).button_pressed:
			out.append(String(id))
	_settings.process_records = out
	changed.emit()


func _on_restart() -> void:
	_settings.save()
	get_tree().paused = false
	get_tree().reload_current_scene()
