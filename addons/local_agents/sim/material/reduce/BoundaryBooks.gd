class_name LABoundaryBooks
extends RefCounted

## `bnd_<channel>` is units crossing the domain edge per step, `bnd_h_<channel>` the joules with them.
## POSITIVE IS INTO THE DOMAIN. A shut wall declares no row, so every book here reads zero.
## LAFieldLedger holds the integrals; this is the binding to them.

const AMOUNT: String = LAReduceBoundaryRows.BOOKED_PREFIX
const HEAT: String = LAReduceBoundaryRows.HEAT_PREFIX

var _n: LAFieldLedger = null

var missing: PackedStringArray:
	get: return _n.boundary_missing()


func _init() -> void:
	_n = LAFieldLedger.new()
	_n.configure(LAFieldLedgerRecords.tables())


## The matter channels this world books a crossing for. An OPEN wall declaring none is not silent
## either: its crossing goes unbooked, reads as drift, and the conservation gate fires. A BOOKED_SIGNED
## channel is not matter, carries no heat leg, and `sample` folds it amount-only.
static func declared() -> PackedStringArray:
	return LAFieldLedger.boundary_declared(LAReduceBoundaryRows.BOOKED_SIGNED)


## Accumulate ONE step's crossings. Called on the field step, so the sum IS the integral and no window is
## extrapolated over. A leg a row promised and the drain did not carry is NAMED.
func sample(f: Dictionary) -> void:
	_n.boundary_sample(f)


## [net in, magnitude crossed, a promised leg is absent] for a channel group. With an element symbol the two
## sums are that element's moles, off the declaration the stock totals are summed with.
func of(group: PackedStringArray, el: String = "") -> Array:
	return _n.boundary_of(group, el)
