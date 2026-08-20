class_name LATransportRecords
extends RefCounted

## What moves, and by what rule. transport.glsl runs every row through one gather.

## What drives a record across a face. Matches the MODE_* constants in transport.glsl.
enum { POTENTIAL, ADVECT, BOTH, DIFFUSE, CONDUCT, RADIATE, SEPARATE }

## The transport law that sets a row's mobility from the cell's own state. Matches LAW_* in transport.glsl.
enum Law { NONE, SHALLOW, FILM, DARCY, EDDY, SOUND, OHMIC, PGF }

## The fluid a row moves THROUGH, whose density and viscosity its law reads.
enum Fluid { VACUUM, WATER, AIR }

## Per-row switches, packed into the kernel's `flags`. Matches the TF_* constants in transport.glsl.
enum Flag { SIGNED = 1, SETTLE = 2, EFIELD = 4, DRIVEN = 8, FRACTION = 16, DILUTE = 32, LISTED = 64,
	RADIOGENIC = 128, ENTHALPY = 256, LIST_HALO = 512 }


## `settle` adds the grain's terminal velocity to the advecting fluid; `frac` is the derived share moved.
static func rows() -> Array:
	return [
		# FIRST: the riming pair separates charge before anything relaxes or carries it.
		{"channel": "charge", "substance": "", "mode": SEPARATE, "signed": true},

		{"channel": "h2o", "substance": "h2o", "mode": POTENTIAL, "law": Law.SHALLOW,
			"frac": "h2o_liquid"},

		{"channel": "h2o", "substance": "h2o", "mode": POTENTIAL, "law": Law.DARCY,
			"fluid": Fluid.WATER, "frac": "h2o_liquid"},

		{"channel": "h2o", "substance": "h2o", "mode": BOTH, "law": Law.EDDY, "fluid": Fluid.AIR,
			"frac": "h2o_vapour"},

		# One silicate channel, four laws. Cemented rock has no row: that is what being rock means.
		# `list` dispatches this row over the compacted melt list — O(molten) rather than O(grid).
		{"channel": "silicate", "substance": "silicate", "mode": POTENTIAL, "law": Law.FILM,
			"frac": "silicate_melt", "dilute": true, "list": "melt"},

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

		{"channel": "fungus", "substance": "cellulose", "mode": ADVECT, "fluid": Fluid.AIR},

		{"channel": "fert", "substance": "fixed_n", "mode": DIFFUSE, "law": Law.DARCY,
			"fluid": Fluid.WATER},

		{"channel": "shock", "substance": "", "mode": DIFFUSE, "law": Law.SOUND, "fluid": Fluid.AIR},

		{"channel": "charge", "substance": "", "mode": DIFFUSE, "law": Law.OHMIC, "fluid": Fluid.AIR,
			"efield": true},

		# The heat equation: conduction down the temperature gradient, and the rock's own decay as the
		# volumetric source term beside it.
		{"channel": "h_j_m3", "substance": "", "mode": CONDUCT,
			"drive": "temp", "aux": "conductivity", "radiogenic": true},

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


## Compacted cell lists, built by transport.glsl's PASS_LIST_* dispatches before any listed row runs.
## `prim` is the channel the append's predicate reads; `halo` adds the receivers of a listed cell's
## outflow; `emit_idx` reads the indices back at the drain.
static func lists() -> Array:
	return [
		# MELT reproduces the FILM row's own no-op: no melt share, or cemented into rock, and it moves nothing.
		{"label": "melt", "prim": "silicate_melt", "halo": true},
		# STRIKE gives a bolt its position without anything walking the grid. No halo: a flash is where it
		# struck. Built before the rows run, so the list carries the previous step's strikes.
		{"label": "strike", "prim": "strike", "halo": false, "emit_idx": true},
	]


## The compacted-index / dispatch-args / membership-flag buffer keys of one list; empty for no such label.
static func list_buffers(label: String) -> Dictionary:
	for row: Dictionary in lists():
		if String(row["label"]) == label:
			return {"idx": label + "_list_idx", "args": label + "_list_args",
				"flag": label + "_list_flag"}
	return {}


## Density and dynamic viscosity of one Fluid, kg/m^3 and Pa s.
static func fluid_properties(fluid: int) -> Vector2:
	if fluid == Fluid.WATER:
		return Vector2(LAPhysical.WATER_DENSITY_KG_M3, LAPhysical.WATER_DYNAMIC_VISCOSITY_PA_S)
	if fluid == Fluid.AIR:
		return Vector2(LAPhysical.AIR_DENSITY_KG_M3, LAPhysical.AIR_DYNAMIC_VISCOSITY_PA_S)
	return Vector2.ZERO


## Channels this table moves; absent means it does not travel.
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
