class_name LABoundaryBooks
extends RefCounted

## `bnd_<channel>` is units crossing the domain edge per step, `bnd_h_<channel>` the joules with them.
## POSITIVE IS INTO THE DOMAIN. A shut wall declares no row, so every book here reads zero.

const Rec: GDScript = preload("res://addons/local_agents/sim/material/ReduceRecords.gd")
const AMOUNT: String = "bnd_"
const HEAT: String = "bnd_h_"

static var _declared: PackedStringArray = PackedStringArray()
static var _scanned: bool = false

var missing: PackedStringArray = PackedStringArray()
var heat_net: float = 0.0
var heat_gross: float = 0.0
var _net: Dictionary = {}
var _gross: Dictionary = {}


## Channels a reduce row promises a crossing for. An OPEN wall declaring none is not silent either: its
## crossing goes unbooked, reads as drift, and the conservation gate fires.
static func declared() -> PackedStringArray:
	if _scanned:
		return _declared
	_scanned = true
	for row: Dictionary in Rec.rows():
		var key: String = String(row["key"])
		if key.begins_with(AMOUNT) and not key.begins_with(HEAT):
			_declared.append(key.substr(AMOUNT.length()))
	return _declared


## Integrate one drain's crossings over `steps`, rectangle rule at the window's right-hand end — the shape
## and the window the energy books already use. A leg a row promised and the drain did not carry is NAMED.
func sample(f: Dictionary, steps: float) -> void:
	missing = PackedStringArray()
	for ch in declared():
		var a: String = AMOUNT + String(ch)
		var h: String = HEAT + String(ch)
		if not f.has(a):
			missing.append(a)
		if not f.has(h):
			missing.append(h)
		if not f.has(a) or not f.has(h):
			continue
		var d: float = float(f[a]) * steps
		var dh: float = float(f[h]) * steps
		_net[ch] = float(_net.get(ch, 0.0)) + d
		_gross[ch] = float(_gross.get(ch, 0.0)) + absf(d)
		heat_net += dh
		heat_gross += absf(dh)


## [net in, magnitude crossed, a promised leg is absent] for a channel group. With an element symbol the two
## sums are that element's moles, off the declaration the stock totals are summed with.
func of(group: PackedStringArray, el: String = "") -> Array:
	var starved: bool = false
	for name in group:
		if missing.has(AMOUNT + String(name)):
			starved = true
	if el == "":
		return [LAFieldLedgerRecords.sum_of(_net, group),
			LAFieldLedgerRecords.sum_of(_gross, group), starved]
	var e_in: Dictionary = LAFieldLedgerRecords.elements_of(_only(_net, group))
	var e_gr: Dictionary = LAFieldLedgerRecords.elements_of(_only(_gross, group))
	return [float(e_in.get(el, 0.0)), float(e_gr.get(el, 0.0)), starved]


static func _only(m: Dictionary, group: PackedStringArray) -> Dictionary:
	var out: Dictionary = {}
	for name in group:
		out[name] = float(m.get(name, 0.0))
	return out
