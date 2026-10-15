class_name LAFieldEnthalpySeed
extends RefCounted

## A cell's enthalpy per entry at a temperature; LAFieldCellMass3D.seed_enthalpy seeds the field's own.

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

