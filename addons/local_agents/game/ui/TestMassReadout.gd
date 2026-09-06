class_name LATestMassReadout
extends VBoxContainer

## THE TEST MASS, READ OFF THE INTEGRATOR: the gravity the probe was released in, how fast it is going
## and how long it has been falling, plus the button that releases another one.

signal drop_requested

const ROWS: Array = [["Local g", "g_release", "%.2f m/s²"], ["Speed", "speed", "%.0f m/s"],
	["Fall", "fall_time_s", "%.1f s"], ["Drop", "height_m", "%.0f m"]]

var _probes: Node = null
var _values: Dictionary
var _landed: Label = null


func setup(probes: Node) -> void:
	_probes = probes


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
	_landed = Label.new()
	add_child(_landed)
	var drop: Button = Button.new()
	drop.text = "Drop a test mass (G)"
	drop.pressed.connect(func() -> void: drop_requested.emit())
	add_child(drop)
	refresh()


## The newest probe's own state. A world that has dropped none reads em dashes, never zeroes.
func refresh() -> void:
	var rows: Array = _probes.rows() if _probes != null else []
	var newest: Dictionary = rows[rows.size() - 1] if not rows.is_empty() else {}
	for spec: Array in ROWS:
		var label: Label = _values[String(spec[0])]
		label.text = (String(spec[2]) % float(newest[String(spec[1])])) if newest.has(String(spec[1])) \
			else "—"
	_landed.text = "%d dropped, %d landed" % [rows.size(), _probes.fallen() if _probes != null else 0]
