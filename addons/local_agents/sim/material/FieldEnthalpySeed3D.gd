class_name LAFieldEnthalpySeed
extends RefCounted

## Fill the enthalpy state from a starting TEMPERATURE, once the channels holding matter are seeded.
## Seeding-phase creation: every joule is declared through the seal.

const PC: GDScript = preload("res://addons/local_agents/sim/material/PhysicalConstants.gd")


## The cell's enthalpy at (t, p) decomposed the way state_derive.glsl carries it: the two ladder entries
## off their own curves, everything else lumped sensible at LAMatterChannels' capacities. Joules and J/K.
static func entry_enthalpies(masses: Dictionary, n_gas_mol: float, t_c: float, p_pa: float) -> Dictionary:
	var h_h2o: float = 0.0
	var h_sil: float = 0.0
	var mc: float = 0.0
	for id in masses:
		var m: float = float(masses[id])
		if m <= 0.0:
			continue
		match LAMatterChannels.entry_of(String(id)):
			LAMatterChannels.Entry.H2O:
				h_h2o += m * LAMixtureEnthalpy.specific_enthalpy(String(id), t_c, p_pa, m, n_gas_mol)
			LAMatterChannels.Entry.SILICATE:
				h_sil += m * LAMixtureEnthalpy.specific_enthalpy(String(id), t_c, p_pa, m, n_gas_mol)
			_:
				mc += m * LAMatterChannels.specific_heat(String(id))
	return {"h_h2o": h_h2o, "h_silicate": h_sil,
		"h_sensible": mc * (t_c + PC.KELVIN_OFFSET), "cap_sensible": mc}


## Seed `_h` so every cell starts at its own `t_c` at the pressure it stands under.
static func seed(f, geotherm: Dictionary, p_pa: PackedFloat32Array) -> void:
	if f._cell_count <= 0 or f._grid == null or geotherm.is_empty() or p_pa.size() != f._cell_count:
		push_error("LAFieldEnthalpySeed: no grid, no marched pressure or no geotherm to seed the ladder on.")
		return
	var r: Dictionary = LAFieldCellMass3D.seed_enthalpy(f, f._grid, geotherm["profile"],
		float(geotherm["r_body"]), float(geotherm["t_surface_c"]), p_pa, f._surface_depth)
	f._h = r["h"]
	if f._seal != null:
		f._seal.note_creation("seed_enthalpy_j", float(r["total_j"]))
