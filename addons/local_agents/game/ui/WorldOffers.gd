class_name LAWorldOffers
extends RefCounted

## What this world holds, for the controls that would otherwise offer what is not there. One answer per
## control class, off LAProcessSet and LAAblate; nothing here keeps a list per rung.

## A control's declared requirement of the SITE, in the rows that carry one.
const NEEDS_OPEN_WATER: String = "open_water"

const GRAVITY_PASS: String = "GravityPass.gd"
const MOMENTUM_TRANSPORT: String = "mom_flux"
const HEAT_CHANNEL: String = "e_j_m3"
const ROCK_CHANNEL: String = "silicate"


static var _field = null


## The field these answers read the site off. Bound before any control is built; nothing keeps a copy.
static func bind_field(field) -> void:
	_field = field


## OPEN WATER, WHEREVER IT STANDS: open cells of the field holding liquid, off the device's own `wet_cells`
## reduction. A stream, a lake and a sea are one answer, and never a list of kinds. False before the first
## drain, which has measured nothing yet.
static func has_open_water() -> bool:
	return _field != null and _field._queries.wet_cell_count() > 0


## What a species asks of the site, off its own record: an aquatic one needs water standing in the box.
static func offers_species(kind: String) -> bool:
	if not has_life():
		return false
	return has_open_water() if bool(LASpeciesLibrary.load_config(kind).get("aquatic", false)) else true


## Living things: creatures, their behaviours, their populations, and anything that only they make.
static func has_life() -> bool:
	return not LAAblate.fauna_off()


## Plants and the biosphere channels they drive.
static func has_flora() -> bool:
	return not LAAblate.flora_off()


## A field channel this world MOVES: a channel nothing transports holds its seeded value everywhere.
## Asked of THIS world's own LIVE transport rows, never of the ladder's whole table, so a row switched
## off mid-run stops being offered the same step.
static func moves(channel: String) -> bool:
	for row: Dictionary in LAProcessSet.transport_rows():
		var legs: Array = row["books"] if row.has("books") else [row.get("channel", "")]
		if legs.has(channel) and LAProcessSet.is_active("transport", String(row.get("label", ""))):
			return true
	return false


## The wind: a velocity exists only where momentum is transported.
static func has_wind() -> bool:
	return LAProcessSet.is_active("transport", MOMENTUM_TRANSPORT)


## The solved gravity field.
static func has_gravity() -> bool:
	return LAProcessSet.is_active("pass", GRAVITY_PASS)


## More than one body to look at: the solar view frames the system this world orbits in.
static func has_system() -> bool:
	return has_gravity()


## An arrival from outside: the rock falls under the solved gravity, the heat of its impact leaves the
## crater by conduction, and the rock it excavates is thrown. Without all three there is nothing to hit.
static func has_impacts() -> bool:
	return impacts_missing().is_empty()


## The impact processes this world lacks, in the order they act.
static func impacts_missing() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if not has_gravity():
		out.append(GRAVITY_PASS)
	if not moves(HEAT_CHANNEL):
		out.append(HEAT_CHANNEL)
	if not moves(ROCK_CHANNEL):
		out.append(ROCK_CHANNEL)
	return out
