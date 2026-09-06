class_name LATransportRecords
extends RefCounted

## WHAT MOVES, AND HOW IT SLIPS THROUGH THE MIXTURE. flux.glsl solves one interface velocity per
## face; each record names the phase share riding it and the closure giving that phase its own drift.

## What a record's matter rides. Matches the MODE_* constants in flux.glsl.
enum { POTENTIAL, ADVECT, BOTH, DIFFUSE, CONDUCT, RADIATE, SEPARATE }

## The closure that gives a phase its drift or a face its diffusivity. Matches LAW_* in flux.glsl.
enum Law { NONE, SHALLOW, FILM, DARCY, EDDY, OHMIC, ESCAPE }

## The fluid a record moves THROUGH, whose density and viscosity its closure reads.
enum Fluid { VACUUM, WATER, AIR }

## Per-record switches, packed into the kernel's `flags`. Matches the TF_* constants in flux.glsl.
enum Flag { SETTLE = 2, EFIELD = 4, FRACTION = 16, DILUTE = 32,
	RADIOGENIC = 64, ENERGY = 128, RELAX = 256, VEL = 512, WATER = 2048, LATTICE = 4096 }


## `settle` adds the grain's terminal velocity; `frac` is the derived share moved; `relax` carries
## the boundary rim's nudge, once per channel. `label` is the record's one name.
static func rows() -> Array:
	return [
		# FIRST: the riming pair separates charge before anything relaxes or carries it.
		{"label": "charge_separate", "channel": "charge", "substance": "", "mode": SEPARATE},

		{"label": "h2o_surface", "channel": "h2o", "substance": "h2o", "mode": POTENTIAL,
			"law": Law.SHALLOW, "frac": "h2o_liquid"},

		{"label": "h2o_groundwater", "channel": "h2o_pore", "substance": "h2o", "mode": POTENTIAL,
			"law": Law.DARCY, "fluid": Fluid.WATER},

		# One silicate channel, four closures. Cemented rock has none: that is what being rock means.
		{"label": "silicate_melt_film", "channel": "silicate", "substance": "silicate",
			"mode": POTENTIAL, "law": Law.FILM, "frac": "silicate_melt", "dilute": true},

		{"label": "silicate_susp_water", "channel": "silicate", "substance": "silicate", "mode": ADVECT,
			"fluid": Fluid.WATER, "settle": true, "frac": "silicate_susp_water", "dilute": true},

		{"label": "silicate_susp_air", "channel": "silicate", "substance": "silicate", "mode": ADVECT,
			"fluid": Fluid.AIR, "settle": true, "frac": "silicate_susp_air", "dilute": true,
			"relax": true},

		{"label": "silicate_bed", "channel": "silicate", "substance": "silicate", "mode": POTENTIAL,
			"law": Law.SHALLOW, "repose_tan": LAPhysical.REPOSE_TAN_DRY_GRANULAR,
			"frac": "silicate_bed", "dilute": true},

		{"label": "fungus_wind", "channel": "fungus", "substance": "cellulose", "mode": ADVECT,
			"fluid": Fluid.AIR, "relax": true},

		{"label": "fert_soil", "channel": "fert", "substance": "fixed_n", "mode": DIFFUSE,
			"law": Law.DARCY, "fluid": Fluid.WATER, "relax": true},

		{"label": "charge_ohmic", "channel": "charge", "substance": "", "mode": DIFFUSE,
			"law": Law.OHMIC, "fluid": Fluid.AIR, "efield": true},

		# The heat equation: conduction down the temperature gradient, and the rock's own decay as the
		# volumetric source term beside it.
		{"label": "heat_conduct", "channel": "e_j_m3", "substance": "", "mode": CONDUCT,
			"drive": "temp", "aux": "conductivity", "relax": true},
		{"label": "heat_conduct_lith", "channel": "e_lith_j_m3", "substance": "", "mode": CONDUCT, "drive": "temp_lith", "aux": "conductivity_lith", "radiogenic": true, "relax": true, "lattice": true},

		{"label": "heat_radiate", "channel": "e_j_m3", "substance": "", "mode": RADIATE},

		# THE ACOUSTIC GROUP: every compressible substance rides the one interface velocity the face
		# solved, and the momentum record closes it with the pressure that velocity came from.
		{"label": "h2o_liquid_advect", "channel": "h2o", "substance": "h2o", "mode": ADVECT,
			"fluid": Fluid.WATER, "frac": "h2o_liquid", "acoustic": true},

		{"label": "h2o_vapour_eddy", "channel": "h2o", "substance": "h2o", "mode": BOTH, "law": Law.EDDY,
			"fluid": Fluid.AIR, "frac": "h2o_vapour", "relax": true, "acoustic": true},

		{"label": "o2_eddy", "channel": "o2", "substance": "o2", "mode": BOTH, "law": Law.EDDY,
			"fluid": Fluid.AIR, "relax": true, "acoustic": true},
		{"label": "co2_eddy", "channel": "co2", "substance": "co2", "mode": BOTH, "law": Law.EDDY,
			"fluid": Fluid.AIR, "relax": true, "acoustic": true},
		{"label": "n2_eddy", "channel": "n2", "substance": "n2", "mode": BOTH, "law": Law.EDDY,
			"fluid": Fluid.AIR, "relax": true, "acoustic": true},
		{"label": "h2_eddy", "channel": "h2", "substance": "h2", "mode": BOTH, "law": Law.EDDY,
			"fluid": Fluid.AIR, "relax": true, "acoustic": true},
		{"label": "co_eddy", "channel": "co", "substance": "co", "mode": BOTH, "law": Law.EDDY,
			"fluid": Fluid.AIR, "relax": true, "acoustic": true},
		{"label": "so2_eddy", "channel": "so2", "substance": "so2", "mode": BOTH, "law": Law.EDDY,
			"fluid": Fluid.AIR, "relax": true, "acoustic": true},
		{"label": "h2s_eddy", "channel": "h2s", "substance": "h2s", "mode": BOTH, "law": Law.EDDY,
			"fluid": Fluid.AIR, "relax": true, "acoustic": true},
		{"label": "ch4_eddy", "channel": "ch4", "substance": "ch4", "mode": BOTH, "law": Law.EDDY,
			"fluid": Fluid.AIR, "relax": true, "acoustic": true},

		# THE MOMENTUM RECORD, last of the group and the only reader of the interface pressure. Bulk
		# advection is not here: it emerges from the mass the records above moved.
		{"label": "mom_flux", "channel": "mom_x", "substance": "", "mode": POTENTIAL,
			"law": Law.EDDY, "fluid": Fluid.AIR, "momentum": true, "acoustic": true,
			"books": ["mom_x", "mom_y", "mom_z"]},
	] + escape_rows()


## LAST: the SPACE faces. Every gas carries the one law; the computed parameter keeps the heavy ones in.
static func escape_rows() -> Array:
	var out: Array = []
	for gas: String in LAMatterChannels.GASES:
		out.append({"label": "escape_" + gas, "channel": gas, "substance": gas, "mode": POTENTIAL,
			"law": Law.ESCAPE})
	out.append({"label": "escape_h2o", "channel": "h2o", "substance": "h2o", "mode": POTENTIAL,
		"law": Law.ESCAPE, "frac": "h2o_vapour"})
	return out


## DETECTORS, not dispatch lists: what a record runs over is its group's active cells. Each compacts
## the cells where `prim` is positive so the drain can read WHERE, without a CPU walk of the grid.
static func lists() -> Array:
	return [
		# STRIKE gives a bolt its position. Built before the records run, so the list carries the
		# previous step's strikes.
		{"label": "strike", "prim": "strike", "emit_idx": true},
		# WHERE the derive's detect phase found melt standing in the open, and where it found a closed
		# warm-core low. Both are written this step, before this pass runs.
		{"label": "erupt", "prim": "erupt", "emit_idx": true},
		{"label": "cyclone", "prim": "cyclone", "emit_idx": true},
	]


## The compacted-index and dispatch-args buffer keys of one detector list; empty for no such label.
static func list_buffers(label: String) -> Dictionary:
	for row: Dictionary in lists():
		if String(row["label"]) == label:
			return {"idx": label + "_list_idx", "args": label + "_list_args"}
	return {}


## Amount at which a cell is full: mol/m^3 of the pure substance.
static func max_fill(substance: String) -> float:
	return LASubstances.full_mol_m3(substance)
