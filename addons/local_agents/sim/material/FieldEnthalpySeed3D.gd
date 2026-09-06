class_name LAFieldEnthalpySeed
extends RefCounted

## Fill the enthalpy state from a starting TEMPERATURE, once the channels holding matter are seeded.
## Seeding-phase creation: every joule is declared through the seal.

## The cell's enthalpy at (t, p) as state_derive.glsl carries it: EVERY substance off its own ladder.
static func entry_enthalpies(masses: Dictionary, room_m3: float, t_c: float, p_pa: float) -> Dictionary:
	var h: PackedFloat64Array = PackedFloat64Array([0.0, 0.0, 0.0])
	var mc: float = 0.0
	for id in masses:
		var m: float = float(masses[id])
		if m <= 0.0:
			continue
		var e: int = LAMatterChannels.entry_of(String(id))
		h[e] += m * LAMixtureEnthalpy.specific_enthalpy(String(id), t_c, p_pa, m, room_m3)
		if e == LAMatterChannels.Entry.SENSIBLE:
			mc += m * LAMixtureEnthalpy.phase_specific_heat(String(id), t_c, p_pa)
	return {"h_h2o": h[LAMatterChannels.Entry.H2O], "h_silicate": h[LAMatterChannels.Entry.SILICATE],
		"h_sensible": h[LAMatterChannels.Entry.SENSIBLE], "cap_sensible": mc}


## Seed `_e`, the internal energy of (t_c, p) per cell: the enthalpy there less the fluid's pV.
static func seed(f, t_rock: PackedFloat32Array, p_pa: PackedFloat32Array, p_rock: PackedFloat32Array) -> void:
	if f._cell_count <= 0 or f._grid == null or t_rock.size() != f._cell_count or p_pa.size() != f._cell_count:
		push_error("LAFieldEnthalpySeed: no grid, no marched pressure or no rock temperature to seed the ladder on.")
		return
	var r: Dictionary = LAFieldCellMass3D.seed_enthalpy(f, f._grid, t_rock, LABodySeeds.surface_temp_c(), p_pa, p_rock)
	f._mirrors.set_array("e_j_m3", r["e"])
	f._mirrors.set_array("e_lith_j_m3", r["e_lith"])
	if f._seal != null:
		f._seal.note_creation("seed_energy_j", float(r["total_j"]))
