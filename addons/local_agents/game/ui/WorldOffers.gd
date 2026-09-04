class_name LAWorldOffers
extends RefCounted

## What this world holds, for the controls that would otherwise offer what is not there. One answer per
## control class, off LAProcessSet and LAAblate; nothing here keeps a list per rung.

const GRAVITY_PASS: String = "GravityPass.gd"
const MOMENTUM_TRANSPORT: String = "mom_flux"


## Living things: creatures, their behaviours, their populations, and anything that only they make.
static func has_life() -> bool:
	return not LAAblate.fauna_off()


## Plants and the biosphere channels they drive.
static func has_flora() -> bool:
	return not LAAblate.flora_off()


## A field channel this world MOVES: a channel nothing transports holds its seeded value everywhere.
static func moves(channel: String) -> bool:
	return LAProcessSet.channel_rung(channel) != LAProcessSet.UNSET


## The wind: a velocity exists only where momentum is transported.
static func has_wind() -> bool:
	return LAProcessSet.has_record("transport", MOMENTUM_TRANSPORT)


## The solved gravity field.
static func has_gravity() -> bool:
	return LAProcessSet.has_record("pass", GRAVITY_PASS)


## More than one body to look at: the solar view frames the system this world orbits in.
static func has_system() -> bool:
	return has_gravity()
