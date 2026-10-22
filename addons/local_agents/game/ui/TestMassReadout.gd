class_name LATestMassReadout
extends VBoxContainer

## THE NEWEST PROBE, READ OFF THE INTEGRATOR: the gravity it was released in, the speed it was given, how
## fast it is going now, how long it has been flying, how far it has fallen and how far over the ground it
## has come. `Charge` is the speed the next lob would leave the hand at.

signal drop_requested

const ROWS: Array = [["Local g", "g_release", "%.2f m/s²"], ["Thrown at", "throw_speed_m_s", "%.0f m/s"],
	["Speed", "speed", "%.0f m/s"], ["Flight", "fall_time_s", "%.1f s"],
	["Drop", "height_m", "%.0f m"], ["Range", "range_m", "%.0f m"]]

var _probes: Node = null
var _values: Dictionary
var _charge: Label = null
var _where: Label = null
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
	_charge = Label.new()
	add_child(_charge)
	_where = Label.new()
	add_child(_where)
	_landed = Label.new()
	add_child(_landed)
	var drop: Button = Button.new()
	drop.text = "Drop a test mass (G)"
	drop.pressed.connect(func() -> void: drop_requested.emit())
	add_child(drop)
	refresh()


## The newest probe's own state. A world that has released none reads em dashes, never zeroes.
func refresh() -> void:
	var rows: Array = _probes.rows() if _probes != null else []
	var newest: Dictionary = rows[rows.size() - 1] if not rows.is_empty() else {}
	for spec: Array in ROWS:
		var label: Label = _values[String(spec[0])]
		label.text = (String(spec[2]) % float(newest[String(spec[1])])) if newest.has(String(spec[1])) \
			else "—"
	_charge.text = "Charge %.0f m/s — hold R to lob, [ ] to set" % _throw_speed()
	_where.text = _landing(newest)
	_landed.text = "%d released, %d landed" % [rows.size(), _probes.fallen() if _probes != null else 0]


func _throw_speed() -> float:
	return float(_probes.get_throw_speed_m_s()) if _probes != null else 0.0


## Where the newest probe came to rest: the cell it stopped in and how far over the ground that is from
## where it was let go.
static func _landing(row: Dictionary) -> String:
	if row.is_empty():
		return "Nothing released yet"
	if not bool(row.get("landed", false)):
		return "In flight"
	return "Landed in cell %d, %.0f m out" % [int(row.get("cell", -1)), float(row.get("range_m", 0.0))]
