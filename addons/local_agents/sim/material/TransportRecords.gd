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
enum Flag { SIGNED = 1, SETTLE = 2, EFIELD = 4, DRIVEN = 8, FRACTION = 16, DILUTE = 32, LISTED = 64,
	RADIOGENIC = 128, ENTHALPY = 256, LIST_HALO = 512, RELAX = 1024, VEL = 2048, LEVEL = 4096 }


## `settle` adds the grain's terminal velocity to the advecting fluid; `frac` is the derived share moved.
## `relax` carries the boundary rim's nudge toward a REPLAY face's driving state — once per channel.
static func rows() -> Array:
	return [
		# FIRST: the riming pair separates charge before anything relaxes or carries it.
		{"channel": "charge", "substance": "", "mode": SEPARATE, "signed": true},

		{"channel": "h2o", "substance": "h2o", "mode": POTENTIAL, "law": Law.SHALLOW,
			"frac": "h2o_liquid"},

		{"channel": "h2o", "substance": "h2o", "mode": POTENTIAL, "law": Law.DARCY,
			"fluid": Fluid.WATER, "frac": "h2o_liquid"},

		# One silicate channel, four laws. Cemented rock has no row: that is what being rock means.
		# `list` dispatches this row over the compacted melt list — O(molten) rather than O(grid).
		{"channel": "silicate", "substance": "silicate", "mode": POTENTIAL, "law": Law.FILM,
			"frac": "silicate_melt", "dilute": true, "list": "melt"},

		{"channel": "silicate", "substance": "silicate", "mode": ADVECT, "fluid": Fluid.WATER,
			"settle": true, "frac": "silicate_susp_water", "dilute": true},

		{"channel": "silicate", "substance": "silicate", "mode": ADVECT, "fluid": Fluid.AIR,
			"settle": true, "frac": "silicate_susp_air", "dilute": true, "relax": true},

		{"channel": "silicate", "substance": "silicate", "mode": POTENTIAL, "law": Law.SHALLOW,
			"repose_tan": LAPhysical.REPOSE_TAN_DRY_GRANULAR,
			"frac": "silicate_bed", "dilute": true},

		{"channel": "fungus", "substance": "cellulose", "mode": ADVECT, "fluid": Fluid.AIR,
			"relax": true},

		{"channel": "fert", "substance": "fixed_n", "mode": DIFFUSE, "law": Law.DARCY,
			"fluid": Fluid.WATER, "relax": true},

		{"channel": "shock", "substance": "", "mode": DIFFUSE, "law": Law.SOUND, "fluid": Fluid.AIR},

		{"channel": "charge", "substance": "", "mode": DIFFUSE, "law": Law.OHMIC, "fluid": Fluid.AIR,
			"efield": true},

		# The heat equation: conduction down the temperature gradient, and the rock's own decay as the
		# volumetric source term beside it.
		{"channel": "h_j_m3", "substance": "", "mode": CONDUCT,
			"drive": "temp", "aux": "conductivity", "radiogenic": true, "relax": true},

		{"channel": "h_j_m3", "substance": "", "mode": RADIATE},

		# THE ACOUSTIC GROUP: compressible matter and its momentum advance together on the acoustic
		# substep — a mass flux at frame cadence against a stiff equation of state has loop gain c dt/L.
		{"channel": "h2o", "substance": "h2o", "mode": ADVECT, "fluid": Fluid.WATER,
			"frac": "h2o_liquid", "acoustic": true},

		{"channel": "h2o", "substance": "h2o", "mode": BOTH, "law": Law.EDDY, "fluid": Fluid.AIR,
			"frac": "h2o_vapour", "relax": true, "acoustic": true},

		{"channel": "o2", "substance": "o2", "mode": BOTH, "law": Law.EDDY, "fluid": Fluid.AIR,
			"relax": true, "acoustic": true},
		{"channel": "co2", "substance": "co2", "mode": BOTH, "law": Law.EDDY, "fluid": Fluid.AIR,
			"relax": true, "acoustic": true},
		{"channel": "n2", "substance": "n2", "mode": BOTH, "law": Law.EDDY, "fluid": Fluid.AIR,
			"relax": true, "acoustic": true},
		{"channel": "h2", "substance": "h2", "mode": BOTH, "law": Law.EDDY, "fluid": Fluid.AIR,
			"relax": true, "acoustic": true},
		{"channel": "co", "substance": "co", "mode": BOTH, "law": Law.EDDY, "fluid": Fluid.AIR,
			"relax": true, "acoustic": true},
		{"channel": "so2", "substance": "so2", "mode": BOTH, "law": Law.EDDY, "fluid": Fluid.AIR,
			"relax": true, "acoustic": true},
		{"channel": "h2s", "substance": "h2s", "mode": BOTH, "law": Law.EDDY, "fluid": Fluid.AIR,
			"relax": true, "acoustic": true},
		{"channel": "ch4", "substance": "ch4", "mode": BOTH, "law": Law.EDDY, "fluid": Fluid.AIR,
			"relax": true, "acoustic": true},

		# -grad(p) alone: bulk momentum advection EMERGES from the mass fluxes, each of which carries
		# the donor's momentum share exactly as it carries heat and charge.
		{"channel": "mom_x", "substance": "", "mode": POTENTIAL, "law": Law.PGF, "axis": 0,
			"drive": "pressure", "signed": true},
		{"channel": "mom_y", "substance": "", "mode": POTENTIAL, "law": Law.PGF, "axis": 1,
			"drive": "pressure", "signed": true},
		{"channel": "mom_z", "substance": "", "mode": POTENTIAL, "law": Law.PGF, "axis": 2,
			"drive": "pressure", "signed": true},

		{"channel": "mom_x", "substance": "", "mode": DIFFUSE, "law": Law.EDDY, "axis": 0,
			"fluid": Fluid.AIR, "signed": true, "relax": true},
		{"channel": "mom_y", "substance": "", "mode": DIFFUSE, "law": Law.EDDY, "axis": 1,
			"fluid": Fluid.AIR, "signed": true, "relax": true},
		{"channel": "mom_z", "substance": "", "mode": DIFFUSE, "law": Law.EDDY, "axis": 2,
			"fluid": Fluid.AIR, "signed": true, "relax": true},
	] + escape_rows()


## LAST: the SPACE faces. Every gas carries the one law; the computed parameter keeps the heavy ones in.
static func escape_rows() -> Array:
	var out: Array = []
	for gas: String in LAMatterChannels.GASES:
		out.append({"channel": gas, "substance": gas, "mode": POTENTIAL, "law": Law.ESCAPE})
	out.append({"channel": "h2o", "substance": "h2o", "mode": POTENTIAL, "law": Law.ESCAPE,
		"frac": "h2o_vapour"})
	return out


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
		# WHERE the non-finite conserved values sit, as indices: the finite gate's localizer.
		{"label": "nonfinite", "prim": "nonfinite", "halo": false, "emit_idx": true},
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


## Amount at which a cell is full: mol/m^3 of the pure substance.
static func max_fill(substance: String) -> float:
	return LASubstances.full_mol_m3(substance)
