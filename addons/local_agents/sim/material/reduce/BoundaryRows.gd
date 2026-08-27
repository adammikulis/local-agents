class_name LAReduceBoundaryRows
extends RefCounted

const Rec: GDScript = preload("res://addons/local_agents/sim/material/ReduceRecords.gd")

## Channels whose boundary crossings transport.glsl books. Every transportable conserved channel is here;
## a channel that can cross and is not booked reads as drift and the conservation gate fires.
const BOOKED: PackedStringArray = ["h2o", "silicate", "o2", "co2", "n2", "h2", "co", "so2", "h2s",
	"ch4", "fungus", "fert", "h_j_m3"]

## Channels booked amount-only: neither momentum nor charge is matter, so neither carries a heat leg.
const BOOKED_SIGNED: PackedStringArray = ["mom_x", "mom_y", "mom_z", "charge"]

## The one spelling of a boundary book's key.
const BOOKED_PREFIX: String = "bnd_"
const HEAT_PREFIX: String = "bnd_h_"


## `bnd_<ch>` is the channel's units crossing the domain edge per step, `bnd_h_<ch>` the joules riding
## with them, both volume-integrated to match the stock rows. Positive is into the domain.
static func rows() -> Array:
	var out: Array = []
	for ch in BOOKED:
		out.append({"key": "bnd_" + String(ch), "source": "bnd_" + String(ch),
			"op": Rec.Op.SUM, "mask": Rec.Mask.ALL, "weight": true})
		out.append({"key": "bnd_h_" + String(ch), "source": "bnd_h_" + String(ch),
			"op": Rec.Op.SUM, "mask": Rec.Mask.ALL, "weight": true})
	for ch in BOOKED_SIGNED:
		out.append({"key": "bnd_" + String(ch), "source": "bnd_" + String(ch),
			"op": Rec.Op.SUM, "mask": Rec.Mask.ALL, "weight": true})
	return out
