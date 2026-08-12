class_name LATransportRecords
extends RefCounted

## What moves, and by what rule. transport.glsl runs every row through one gather.
##
## (Explicit types only, no ':=' inferred typing.)

## What drives a record across a face. Matches the MODE_* constants in transport.glsl.
enum { POTENTIAL, ADVECT, BOTH, DIFFUSE }


## `mobility`: fraction of the driving imbalance crossing a face per step. Bounded by stability.
static func rows() -> Array:
	return [
		{"channel": "water", "substance": "h2o", "mode": POTENTIAL,
			"mobility": 0.5, "repose_tan": 0.0, "resist": ""},

		# Pore water: the matrix resists it, so rock_fill is the resistance term.
		{"channel": "soil", "substance": "h2o", "mode": POTENTIAL,
			"mobility": 0.25, "repose_tan": 0.0, "resist": "rock_fill"},

		# Loose grains hold a slope to the angle of repose.
		{"channel": "sediment", "substance": "silicate", "mode": POTENTIAL,
			"mobility": 0.25, "repose_tan": LAPhysical.REPOSE_TAN_DRY_GRANULAR, "resist": ""},

		# Suspended load goes where its water goes.
		{"channel": "susp", "substance": "silicate", "mode": ADVECT,
			"mobility": 0.0, "repose_tan": 0.0, "resist": ""},

		# Wind-carried, settling under gravity.
		{"channel": "dust", "substance": "silicate", "mode": BOTH,
			"mobility": 0.05, "repose_tan": 0.0, "resist": ""},

		{"channel": "lava", "substance": "silicate", "mode": POTENTIAL,
			"mobility": 0.125, "repose_tan": 0.0, "resist": ""},

		# Wind-borne and falling: the two together are what gives an atmosphere a scale height.
		{"channel": "moisture", "substance": "h2o", "mode": BOTH,
			"mobility": 0.05, "repose_tan": 0.0, "resist": ""},
		{"channel": "o2", "substance": "o2", "mode": BOTH,
			"mobility": 0.05, "repose_tan": 0.0, "resist": ""},
		{"channel": "co2", "substance": "co2", "mode": BOTH,
			"mobility": 0.05, "repose_tan": 0.0, "resist": ""},
		{"channel": "n2", "substance": "n2", "mode": BOTH,
			"mobility": 0.05, "repose_tan": 0.0, "resist": ""},

		# Soil nutrient spreads through the ground rather than falling through it.
		{"channel": "fert", "substance": "fixed_n", "mode": DIFFUSE,
			"mobility": 0.1, "repose_tan": 0.0, "resist": ""},

		# A pressure wave spreads from where it was released.
		{"channel": "shock", "substance": "", "mode": DIFFUSE,
			"mobility": 0.25, "repose_tan": 0.0, "resist": ""},
	]


## Channels this table moves. Absent = does not travel (carbonate and silica are locked in their rock).
static func channels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for r in rows():
		out.append(String(r["channel"]))
	return out


## Amount at which a cell is full: mol/m^3 of the pure substance.
static func max_fill(substance: String) -> float:
	var s: Dictionary = LASubstances.table().get(substance, {})
	var rho: float = float(s.get("density", 0.0))
	var m: float = float(s.get("molar_mass", 0.0))
	return (rho / m) if (rho > 0.0 and m > 0.0) else 0.0
