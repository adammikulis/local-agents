class_name LAProcessRungReadout
extends VBoxContainer

## What this world is running and what it costs: the rung it declared, the milliseconds one field step
## took, and how many temporal levels the transport rows asked for. Read off the report, never computed.

const ROWS: Array = [["Rung", ""], ["Step", "field_ms"], ["Levels", "transport_levels"]]

var _values: Dictionary


func _ready() -> void:
	add_theme_constant_override("separation", 2)
	var built: Dictionary = {}
	for spec: Array in ROWS:
		var row: HBoxContainer = HBoxContainer.new()
		var key: Label = Label.new()
		key.text = String(spec[0])
		key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(key)
		var value: Label = Label.new()
		value.text = "—"
		row.add_child(value)
		add_child(row)
		built[String(spec[0])] = value
	_values = built
	refresh()


func refresh() -> void:
	var custom: PackedStringArray = LAProcessSet.custom()
	(_values["Rung"] as Label).text = ("custom (%d)" % custom.size()) if not custom.is_empty() \
		else LAProcessSet.name_of(LAProcessSet.active())
	var snap: Dictionary = LASimReport.snapshot()
	var gauges: Dictionary = snap.get("gauges", {})
	(_values["Step"] as Label).text = _gauge(gauges, "field_ms", "%.1f ms")
	(_values["Levels"] as Label).text = _gauge(gauges, "transport_levels", "%.0f")


## A gauge the run never published is absent, and an absent reading is an em dash, never a zero.
func _gauge(gauges: Dictionary, key: String, fmt: String) -> String:
	if not gauges.has(key):
		return "—"
	var g: Variant = gauges[key]
	var v: Variant = g["cur"] if g is Dictionary and (g as Dictionary).has("cur") else g
	return fmt % float(v) if v is float or v is int else "—"
