class_name LABoundaryBooks
extends RefCounted

## `bnd_<channel>` is units crossing the domain edge per step, `bnd_h_<channel>` the joules with them.
## POSITIVE IS INTO THE DOMAIN. A shut wall declares no row, so every book here reads zero.

const AMOUNT: String = LAReduceBoundaryRows.BOOKED_PREFIX
const HEAT: String = LAReduceBoundaryRows.HEAT_PREFIX

var missing: PackedStringArray = PackedStringArray()
var heat_net: float = 0.0
var heat_gross: float = 0.0
var _net: Dictionary = {}
var _gross: Dictionary = {}


## The matter channels this world books a crossing for. An OPEN wall declaring none is not silent
## either: its crossing goes unbooked, reads as drift, and the conservation gate fires. A BOOKED_SIGNED
## channel is not matter, carries no heat leg, and `sample` folds it amount-only below.
static func declared() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for ch in LAProcessSet.booked():
		if not LAReduceBoundaryRows.BOOKED_SIGNED.has(ch):
			out.append(String(ch))
	return out


## Accumulate ONE step's crossings. Called on the field step, so the sum IS the integral and no window is
## extrapolated over. A leg a row promised and the drain did not carry is NAMED.
func sample(f: Dictionary) -> void:
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
		var d: float = float(f[a])
		var dh: float = float(f[h])
		_net[ch] = float(_net.get(ch, 0.0)) + d
		_gross[ch] = float(_gross.get(ch, 0.0)) + absf(d)
		heat_net += dh
		heat_gross += absf(dh)
	for sch in LAProcessSet.booked():
		if not LAReduceBoundaryRows.BOOKED_SIGNED.has(sch):
			continue
		var sa: String = AMOUNT + String(sch)
		if not f.has(sa):
			missing.append(sa)
			continue
		var sd: float = float(f[sa])
		_net[sch] = float(_net.get(sch, 0.0)) + sd
		_gross[sch] = float(_gross.get(sch, 0.0)) + absf(sd)


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
