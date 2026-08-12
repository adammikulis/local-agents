class_name LATransportRecords
extends RefCounted

## What moves, and by what rule. transport.glsl runs every row through one gather.

## What drives a record across a face. Matches the MODE_* constants in transport.glsl.
enum { POTENTIAL, ADVECT, BOTH, DIFFUSE, CONVECT, CONDUCT, RADIATE }

## The transport law that sets a row's mobility from the cell's own state. Matches LAW_* in transport.glsl.
enum Law { NONE, SHALLOW, FILM, DARCY, EDDY, SOUND, OHMIC, PGF }

## The fluid a row moves THROUGH, whose density and viscosity its law reads.
enum Fluid { VACUUM, WATER, AIR }

## Per-row switches, packed into the kernel's `flags`. Matches the TF_* constants in transport.glsl.
enum Flag { SIGNED = 1, SETTLE = 2, STAMP = 4, DRIVEN = 8, FRACTION = 16, DILUTE = 32 }


## No row carries a mobility: every one names a law, and the law is evaluated per cell on measured
## properties. `settle` adds the grain's own terminal velocity to the fluid velocity that advects it.
## `frac` names a DERIVED share of the channel this row moves — the phase whose law it is.
static func rows() -> Array:
	return [
		# H2O IS ONE CHANNEL AND ITS PHASES TRAVEL DIFFERENTLY. Free liquid runs downhill, pore water
		# percolates, vapour goes with the wind, and the solid share has no row: ice does not flow at this
		# grid's timescale, so it leaves a cell by melting.
		{"channel": "h2o", "substance": "h2o", "mode": POTENTIAL, "law": Law.SHALLOW,
			"frac": "h2o_liquid"},

		{"channel": "h2o", "substance": "h2o", "mode": POTENTIAL, "law": Law.DARCY,
			"fluid": Fluid.WATER, "frac": "h2o_liquid"},

		{"channel": "h2o", "substance": "h2o", "mode": BOTH, "law": Law.EDDY, "fluid": Fluid.AIR,
			"frac": "h2o_vapour"},

		# One silicate channel, four laws. Cemented rock has no row: that is what being rock means.
		{"channel": "silicate", "substance": "silicate", "mode": POTENTIAL, "law": Law.FILM,
			"frac": "silicate_melt", "dilute": true},

		{"channel": "silicate", "substance": "silicate", "mode": ADVECT, "fluid": Fluid.WATER,
			"settle": true, "frac": "silicate_susp_water", "dilute": true},

		{"channel": "silicate", "substance": "silicate", "mode": ADVECT, "fluid": Fluid.AIR,
			"settle": true, "frac": "silicate_susp_air", "dilute": true},

		{"channel": "silicate", "substance": "silicate", "mode": POTENTIAL, "law": Law.SHALLOW,
			"repose_tan": LAPhysical.REPOSE_TAN_DRY_GRANULAR,
			"frac": "silicate_bed", "dilute": true},

		{"channel": "o2", "substance": "o2", "mode": BOTH, "law": Law.EDDY, "fluid": Fluid.AIR},
		{"channel": "co2", "substance": "co2", "mode": BOTH, "law": Law.EDDY, "fluid": Fluid.AIR},
		{"channel": "n2", "substance": "n2", "mode": BOTH, "law": Law.EDDY, "fluid": Fluid.AIR},

		# Spores ride the wind; the settling arm needs a spore diameter no table here declares.
		{"channel": "fungus", "substance": "cellulose", "mode": ADVECT, "fluid": Fluid.AIR},

		{"channel": "fert", "substance": "fixed_n", "mode": DIFFUSE, "law": Law.DARCY,
			"fluid": Fluid.WATER},

		{"channel": "shock", "substance": "", "mode": DIFFUSE, "law": Law.SOUND, "fluid": Fluid.AIR},

		# Lightning is not a mechanism: it is sigma/eps0 relaxation once sigma stops being a dielectric.
		{"channel": "charge", "substance": "", "mode": DIFFUSE, "law": Law.OHMIC, "fluid": Fluid.AIR,
			"stamp": "discharge"},

		{"channel": "h_j_m3", "substance": "", "mode": CONVECT, "law": Law.EDDY, "fluid": Fluid.AIR},

		{"channel": "h_j_m3", "substance": "", "mode": CONDUCT,
			"drive": "temp", "aux": "conductivity"},

		{"channel": "h_j_m3", "substance": "", "mode": RADIATE},

		{"channel": "mom_x", "substance": "", "mode": POTENTIAL, "law": Law.PGF,
			"drive": "pressure", "signed": true},
		{"channel": "mom_y", "substance": "", "mode": POTENTIAL, "law": Law.PGF,
			"drive": "pressure", "signed": true},
		{"channel": "mom_z", "substance": "", "mode": POTENTIAL, "law": Law.PGF,
			"drive": "pressure", "signed": true},

		{"channel": "mom_x", "substance": "", "mode": DIFFUSE, "law": Law.EDDY,
			"fluid": Fluid.AIR, "signed": true},
		{"channel": "mom_y", "substance": "", "mode": DIFFUSE, "law": Law.EDDY,
			"fluid": Fluid.AIR, "signed": true},
		{"channel": "mom_z", "substance": "", "mode": DIFFUSE, "law": Law.EDDY,
			"fluid": Fluid.AIR, "signed": true},
	]


## Density and dynamic viscosity of one Fluid, kg/m^3 and Pa s.
static func fluid_properties(fluid: int) -> Vector2:
	if fluid == Fluid.WATER:
		return Vector2(LAPhysical.WATER_DENSITY_KG_M3, LAPhysical.WATER_DYNAMIC_VISCOSITY_PA_S)
	if fluid == Fluid.AIR:
		return Vector2(LAPhysical.AIR_DENSITY_KG_M3, LAPhysical.AIR_DYNAMIC_VISCOSITY_PA_S)
	return Vector2.ZERO


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
