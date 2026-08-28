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


## Seed `_h` so every cell starts at its own `t_c` AT THE PRESSURE IT STANDS UNDER. The ladder's rungs move with
## pressure, so enthalpy taken at one pressure and inverted at another lands on a different rung: a cell
## seeded liquid at one atmosphere reads superheated once the derive asks it at lithostatic.
static func seed(f, geotherm: Dictionary, p_pa: PackedFloat32Array) -> void:
	if f._cell_count <= 0:
		return
	f._h.resize(f._cell_count)
	var vol: PackedFloat32Array = f._grid.cell_volumes() if f._grid != null else PackedFloat32Array()
	if vol.size() < f._cell_count or p_pa.size() != f._cell_count or geotherm.is_empty():
		push_error("LAFieldEnthalpySeed: no cell volumes, no marched pressure or no geotherm to seed the ladder on.")
		return
	var total_j: float = 0.0
	var centre: Vector3 = f.centre()
	for c in f._cell_count:
		var cell_m3: float = vol[c]
		if cell_m3 <= 0.0: continue
		var t_c: float = LAFieldGeothermSeed.temperature_c_at(geotherm, (f.cell_world_pos_linear(c) - centre).length())
		# masses_at is EMPTY for a cell the substrate calls empty, so it is handed no joules to hold.
		var e: Dictionary = entry_enthalpies(LAFieldCellMass3D.masses_at(f, c, cell_m3),
			LAFieldCellMass3D.gas_moles_at(f, c, cell_m3), t_c, maxf(p_pa[c], 0.0))
		var h_j: float = float(e["h_h2o"]) + float(e["h_silicate"]) + float(e["h_sensible"])
		f._h[c] = h_j / cell_m3
		total_j += h_j
	if f._seal != null:
		f._seal.note_creation("seed_enthalpy_j", total_j)
