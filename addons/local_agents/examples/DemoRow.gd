@tool
class_name LADemoRow
extends PanelContainer
## One demo-catalogue entry as a launcher row: numbered title, description, what it lacks here, Open.

signal launched(entry: LocalAgentDemoEntry)

const NO_ENTRY: String = "No Entry assigned: this row has no demo to show or open."

@export_group("Entry")
@export var entry: LocalAgentDemoEntry:
	set(value):
		entry = value
		update_configuration_warnings()

@export_group("Launch button")
@export var open_text: String = "Open"
@export var unavailable_text: String = "Unavailable"

## The entry's place in the sorted catalogue.
var number: int = 0
## Why this machine cannot open the entry; "" when it can.
var blocked_reason: String = ""

@onready var _title: Label = %Title
@onready var _description: Label = %Description
@onready var _requirements: Label = %Requirements
@onready var _launch: Button = %Launch


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	var problems: PackedStringArray = _get_configuration_warnings()
	if not problems.is_empty():
		push_error("%s: %s" % [get_path(), " ".join(problems)])
		return
	var runnable: bool = blocked_reason == ""
	_title.text = "%d. %s" % [number, entry.title]
	_description.text = entry.description
	_description.visible = entry.description != ""
	_requirements.text = blocked_reason
	_requirements.visible = not runnable
	_launch.text = open_text if runnable else unavailable_text
	_launch.disabled = not runnable
	_launch.tooltip_text = blocked_reason
	_launch.pressed.connect(func() -> void: launched.emit(entry))


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if entry == null:
		out.append(NO_ENTRY)
	return out
