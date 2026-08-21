class_name LAPlanetComposition
extends RefCounted

## The seeded planet's mineralogy, DERIVED from LAElementAbundances: a CIPW-style normative solve turns
## the silicate-Earth element budget into mineral proportions, and the core model into the metal alloy.
## The composition gate (scripts/check_element_composition.sh) closes this against the registry both ways.

const AB = preload("res://addons/local_agents/sim/material/ElementAbundances.gd")

## Channels the shell solve fills, in solve order.
const SHELL_CHANNELS: PackedStringArray = ["olivine", "pyroxene", "plagioclase", "silicate",
	"apatite", "halite"]

static var _shell_cache: Dictionary = {}


## Moles of one element per kg of silicate shell.
static func _mol(el: String) -> float:
	return float(AB.SILICATE_EARTH.get(el, 0.0)) / AB.atomic_mass(el)


## Molar Mg/(Mg+Fe) of the mantle silicates, from the registry's Mg and Fe budgets.
static func mg_number() -> float:
	var mg: float = _mol("Mg")
	return mg / (mg + _mol("Fe"))


## Anorthite fraction of the plagioclase: Na fixes albite, the remaining Al fixes anorthite.
static func an_fraction() -> float:
	var n_ab: float = _mol("Na") - _mol("Cl")
	var n_an: float = (_mol("Al") - n_ab) / 2.0
	return n_an / (n_an + n_ab)


## F occupancy of the apatite anion site; the OH remainder is the registry's F deficit.
static func apatite_f_fraction() -> float:
	return clampf(_mol("F") / (_mol("P") / 3.0), 0.0, 1.0)


static func olivine_formula() -> Dictionary:
	var m: float = mg_number()
	return {"Mg": 2.0 * m, "Fe": 2.0 * (1.0 - m), "Si": 1.0, "O": 4.0}


static func pyroxene_formula() -> Dictionary:
	var m: float = mg_number()
	return {"Mg": m, "Fe": 1.0 - m, "Si": 1.0, "O": 3.0}


static func plagioclase_formula() -> Dictionary:
	var x: float = an_fraction()
	return {"Na": 1.0 - x, "Ca": x, "Al": 1.0 + x, "Si": 3.0 - x, "O": 8.0}


static func apatite_formula() -> Dictionary:
	var y: float = apatite_f_fraction()
	return {"Ca": 5.0, "P": 3.0, "O": 12.0 + (1.0 - y), "F": y, "H": 1.0 - y}


## Metal alloy: mole ratios per mole Fe, from the core model's major-element mass fractions.
static func metal_formula() -> Dictionary:
	var n_fe: float = float(AB.CORE["Fe"]) / AB.atomic_mass("Fe")
	return {"Fe": 1.0,
		"Ni": (float(AB.CORE["Ni"]) / AB.atomic_mass("Ni")) / n_fe,
		"S": (float(AB.CORE["S"]) / AB.atomic_mass("S")) / n_fe,
		"Si": (float(AB.CORE["Si"]) / AB.atomic_mass("Si")) / n_fe}


## kg of each shell mineral per kg of silicate shell. Every proportion is a mole balance against the
## registry; a negative mole count means the mineral basis cannot carry the registry, and is an error.
static func shell_minerals() -> Dictionary:
	if not _shell_cache.is_empty():
		return _shell_cache
	var n_hal: float = _mol("Cl")
	var n_ap: float = _mol("P") / 3.0
	var n_ab: float = _mol("Na") - n_hal
	var n_an: float = (_mol("Al") - n_ab) / 2.0
	var n_plag: float = n_ab + n_an
	var n_wo: float = _mol("Ca") - n_an - 5.0 * n_ap
	var x: float = an_fraction()
	var si_rem: float = _mol("Si") - (3.0 - x) * n_plag - n_wo
	var m_rem: float = _mol("Mg") + _mol("Fe")
	var n_ol: float = m_rem - si_rem
	var n_px: float = 2.0 * si_rem - m_rem
	var moles: Dictionary = {"olivine": n_ol, "pyroxene": n_px, "plagioclase": n_plag,
		"silicate": n_wo, "apatite": n_ap, "halite": n_hal}
	var forms: Dictionary = {"olivine": olivine_formula(), "pyroxene": pyroxene_formula(),
		"plagioclase": plagioclase_formula(), "silicate": {"Ca": 1.0, "Si": 1.0, "O": 3.0},
		"apatite": apatite_formula(), "halite": {"Na": 1.0, "Cl": 1.0}}
	var out: Dictionary = {}
	for id in SHELL_CHANNELS:
		var n: float = float(moles[id])
		if n < 0.0:
			push_error("LAPlanetComposition: the normative solve gives %s a negative mole count (%f)."
				% [id, n])
			return {}
		out[id] = n * AB.molar_mass(forms[id])
	_shell_cache = out
	return out


## Reference density of the shell mineral mix at the seed state, kg/m^3: volumes add.
static func shell_density(t_c: float, p_pa: float) -> float:
	var w: Dictionary = shell_minerals()
	var v: float = 0.0
	var mass: float = 0.0
	for id in w:
		var rho: float = LASubstances.density(String(id), t_c, p_pa)
		if rho <= 0.0:
			return 0.0
		mass += float(w[id])
		v += float(w[id]) / rho
	return mass / v if v > 0.0 else 0.0


## Core radius as a share of the surface radius: the radius at which the metal sphere holds the core's
## declared share of the planet's mass, at the seed-state reference densities.
static func core_radius_frac(t_c: float, p_pa: float) -> float:
	var f: float = AB.CORE_MASS_FRACTION
	var rho_m: float = LASubstances.density("metal", t_c, p_pa)
	var rho_s: float = shell_density(t_c, p_pa)
	if rho_m <= 0.0 or rho_s <= 0.0:
		return 0.0
	return pow(f * rho_s / (rho_m * (1.0 - f) + f * rho_s), 1.0 / 3.0)


## Fill the field's mineral mirrors: a differentiated body — metal core, one silicate shell of the
## registry's own mineral mix. Differentiation at ~10^13 steps is not computable, so the layering is
## seeded; the maintainer's decision, not a law.
static func seed(f, t_c: float) -> void:
	var w: Dictionary = shell_minerals()
	if w.is_empty() or f._grid == null:
		return
	var p_std: float = LAPhysical.STANDARD_PRESSURE_PA
	var amounts: Dictionary = {}
	for id in w:
		amounts[id] = 0.0
	var v_shell: float = 0.0
	for id in w:
		var rho: float = LASubstances.density(String(id), t_c, p_std)
		v_shell += float(w[id]) / rho
	for id in w:
		var rho2: float = LASubstances.density(String(id), t_c, p_std)
		var vf: float = (float(w[id]) / rho2) / v_shell
		var mm: float = float(LASubstances.table()[String(id)]["molar_mass"])
		amounts[id] = vf * rho2 / mm
	var metal_full: float = LASubstances.density("metal", t_c, p_std) \
		/ float(LASubstances.table()["metal"]["molar_mass"])
	var centre: Vector3 = LAFieldGeometry.centre(f)
	var r_max: float = 0.0
	for c in f._cell_count:
		if f._solid[c] != 0:
			r_max = maxf(r_max, (f._grid.cell_world_pos(c) - centre).length())
	var r_core: float = r_max * core_radius_frac(t_c, p_std)
	for c in f._cell_count:
		var solid: bool = f._solid[c] != 0
		f._cement[c] = 1.0 if solid else 0.0
		if not solid:
			continue
		if (f._grid.cell_world_pos(c) - centre).length() < r_core:
			f._metal[c] = metal_full
			continue
		f._silicate[c] = float(amounts["silicate"])
		f._olivine[c] = float(amounts["olivine"])
		f._pyroxene[c] = float(amounts["pyroxene"])
		f._plagioclase[c] = float(amounts["plagioclase"])
		f._apatite[c] = float(amounts["apatite"])
		f._halite[c] = float(amounts["halite"])
