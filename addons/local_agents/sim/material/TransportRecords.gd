class_name LATransportRecords
extends RefCounted

## What moves, and by what rule. transport.glsl runs every row through one gather.

## What drives a record across a face. Matches the MODE_* constants in transport.glsl.
enum { POTENTIAL, ADVECT, BOTH, DIFFUSE, CONDUCT, RADIATE, SEPARATE }

## The transport law that sets a row's mobility from the cell's own state. Matches LAW_* in transport.glsl.
enum Law { NONE, SHALLOW, FILM, DARCY, EDDY, SOUND, OHMIC, PGF, ESCAPE }

## The fluid a row moves THROUGH, whose density and viscosity its law reads.
enum Fluid { VACUUM, WATER, AIR }

## Per-row switches, packed into the kernel's `flags`. Matches the TF_* constants in transport.glsl.
enum Flag { SIGNED = 1, SETTLE = 2, EFIELD = 4, DRIVEN = 8, FRACTION = 16, DILUTE = 32,
	RADIOGENIC = 64, ENTHALPY = 128, RELAX = 256, VEL = 512, LEVEL = 1024 }


## `settle` adds the grain's terminal velocity to the advecting fluid; `frac` is the derived share moved.
## `relax` carries the boundary rim's nudge toward a REPLAY face's driving state — once per channel.
## `label` is the row's one name; LAProcessSet assigns each to exactly one rung.
static func rows() -> Array:
	return [
		# FIRST: the riming pair separates charge before anything relaxes or carries it.
		{"label": "charge_separate", "channel": "charge", "substance": "", "mode": SEPARATE,
			"signed": true},

		{"label": "h2o_surface", "channel": "h2o", "substance": "h2o", "mode": POTENTIAL,
			"law": Law.SHALLOW, "frac": "h2o_liquid"},

		{"label": "h2o_groundwater", "channel": "h2o", "substance": "h2o", "mode": POTENTIAL,
			"law": Law.DARCY, "fluid": Fluid.WATER, "frac": "h2o_liquid"},

		# One silicate channel, four laws. Cemented rock has no row: that is what being rock means.
		{"label": "silicate_melt_film", "channel": "silicate", "substance": "silicate", "mode": POTENTIAL,
			"law": Law.FILM, "frac": "silicate_melt", "dilute": true},

		{"label": "silicate_susp_water", "channel": "silicate", "substance": "silicate", "mode": ADVECT,
			"fluid": Fluid.WATER, "settle": true, "frac": "silicate_susp_water", "dilute": true},

		{"label": "silicate_susp_air", "channel": "silicate", "substance": "silicate", "mode": ADVECT,
			"fluid": Fluid.AIR, "settle": true, "frac": "silicate_susp_air", "dilute": true, "relax": true},

		{"label": "silicate_bed", "channel": "silicate", "substance": "silicate", "mode": POTENTIAL,
			"law": Law.SHALLOW, "repose_tan": LAPhysical.REPOSE_TAN_DRY_GRANULAR,
			"frac": "silicate_bed", "dilute": true},

		{"label": "fungus_wind", "channel": "fungus", "substance": "cellulose", "mode": ADVECT,
			"fluid": Fluid.AIR, "relax": true},

		{"label": "fert_soil", "channel": "fert", "substance": "fixed_n", "mode": DIFFUSE,
			"law": Law.DARCY, "fluid": Fluid.WATER, "relax": true},

		{"label": "shock_sound", "channel": "shock", "substance": "", "mode": DIFFUSE, "law": Law.SOUND,
			"fluid": Fluid.AIR},

		{"label": "charge_ohmic", "channel": "charge", "substance": "", "mode": DIFFUSE, "law": Law.OHMIC,
			"fluid": Fluid.AIR, "efield": true},

		# The heat equation: conduction down the temperature gradient, and the rock's own decay as the
		# volumetric source term beside it.
		{"label": "heat_conduct", "channel": "h_j_m3", "substance": "", "mode": CONDUCT,
			"drive": "temp", "aux": "conductivity", "radiogenic": true, "relax": true},

		{"label": "heat_radiate", "channel": "h_j_m3", "substance": "", "mode": RADIATE},

		# THE ACOUSTIC GROUP: compressible matter and its momentum advance together on the acoustic
		# substep — a mass flux at frame cadence against a stiff equation of state has loop gain c dt/L.
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

		# -grad(p) alone: bulk momentum advection EMERGES from the mass fluxes, each of which carries
		# the donor's momentum share exactly as it carries heat and charge.
		{"label": "mom_x_pgf", "channel": "mom_x", "substance": "", "mode": POTENTIAL,
			"law": Law.PGF, "axis": 0, "drive": "pressure", "signed": true},
		{"label": "mom_y_pgf", "channel": "mom_y", "substance": "", "mode": POTENTIAL,
			"law": Law.PGF, "axis": 1, "drive": "pressure", "signed": true},
		{"label": "mom_z_pgf", "channel": "mom_z", "substance": "", "mode": POTENTIAL,
			"law": Law.PGF, "axis": 2, "drive": "pressure", "signed": true},

		{"label": "mom_x_eddy", "channel": "mom_x", "substance": "", "mode": DIFFUSE,
			"law": Law.EDDY, "axis": 0, "fluid": Fluid.AIR, "signed": true, "relax": true},
		{"label": "mom_y_eddy", "channel": "mom_y", "substance": "", "mode": DIFFUSE,
			"law": Law.EDDY, "axis": 1, "fluid": Fluid.AIR, "signed": true, "relax": true},
		{"label": "mom_z_eddy", "channel": "mom_z", "substance": "", "mode": DIFFUSE,
			"law": Law.EDDY, "axis": 2, "fluid": Fluid.AIR, "signed": true, "relax": true},
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


## DETECTORS, not dispatch lists: what a row runs over is its group's active cells. Each compacts the
## cells where `prim` is positive so the drain can read WHERE, without a CPU walk of the grid.
static func lists() -> Array:
	return [
		# STRIKE gives a bolt its position. Built before the rows run, so the list carries the
		# previous step's strikes.
		{"label": "strike", "prim": "strike", "emit_idx": true},
	]


## The compacted-index and dispatch-args buffer keys of one detector list; empty for no such label.
static func list_buffers(label: String) -> Dictionary:
	for row: Dictionary in lists():
		if String(row["label"]) == label:
			return {"idx": label + "_list_idx", "args": label + "_list_args"}
	return {}


## Density and dynamic viscosity of one Fluid, kg/m^3 and Pa s.
static func fluid_properties(fluid: int) -> Vector2:
	if fluid == Fluid.WATER:
		return Vector2(LAPhysical.WATER_DENSITY_KG_M3, LAPhysical.WATER_DYNAMIC_VISCOSITY_PA_S)
	if fluid == Fluid.AIR:
		return Vector2(LAPhysical.AIR_DENSITY_KG_M3, LAPhysical.AIR_DYNAMIC_VISCOSITY_PA_S)
	return Vector2.ZERO


## Amount at which a cell is full: mol/m^3 of the pure substance.
static func max_fill(substance: String) -> float:
	return LASubstances.full_mol_m3(substance)
