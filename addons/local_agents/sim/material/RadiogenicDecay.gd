class_name LARadiogenicDecay
extends RefCounted

const PC: GDScript = preload("res://addons/local_agents/sim/material/PhysicalConstants.gd")

## The abundances every entry in LASubstances is quoted at: today. Years run forward from there, so this
## world's own epoch is NEGATIVE and the nuclide store is fuller than Earth's is now.
static func epoch_years() -> float:
	var clock = LASimClock.active()
	if clock == null:
		return -PC.EARTH_FORMATION_AGE_YEARS
	return -PC.EARTH_FORMATION_AGE_YEARS + clock.elapsed() / PC.SECONDS_PER_YEAR


## nuclide -> [kg of nuclide per kg of THIS rock today, half-life years, decay energy J per decay,
## molar mass]. Rocks differ: a limestone is not a mantle peridotite and neither is quartz sand.
static func nuclides(substance: String) -> Dictionary:
	var s: Dictionary = LASubstances.table().get(substance, {})
	var u: float = float(s.get("u_kg_per_kg", 0.0))
	var th: float = float(s.get("th_kg_per_kg", 0.0))
	var k: float = float(s.get("k_kg_per_kg", 0.0))
	return {
		"U238":  [u * PC.ISOTOPE_FRAC_U238, PC.HALF_LIFE_U238_YEARS,
			PC.DECAY_ENERGY_U238_MEV * PC.MEV_J, PC.MOLAR_MASS_U238_KG_MOL],
		"U235":  [u * PC.ISOTOPE_FRAC_U235, PC.HALF_LIFE_U235_YEARS,
			PC.DECAY_ENERGY_U235_MEV * PC.MEV_J, PC.MOLAR_MASS_U235_KG_MOL],
		"TH232": [th * PC.ISOTOPE_FRAC_TH232, PC.HALF_LIFE_TH232_YEARS,
			PC.DECAY_ENERGY_TH232_MEV * PC.MEV_J, PC.MOLAR_MASS_TH232_KG_MOL],
		"K40":   [k * PC.ISOTOPE_FRAC_K40, PC.HALF_LIFE_K40_YEARS,
			PC.DECAY_ENERGY_K40_MEV * PC.MEV_J, PC.MOLAR_MASS_K40_KG_MOL],
	}


## Watts per kilogram of `substance`, `years` after the present epoch; negative reaches into the past.
static func heat_production_w_kg_at(substance: String, years: float) -> float:
	var w: float = 0.0
	for row in nuclides(substance).values():
		w += _w_per_kg(row[0], row[1], row[2], row[3]) * pow(2.0, -years / float(row[1]))
	return w


## Watts per cubic metre of pure `substance` at `years`: what a cell holding one unit of it produces.
static func heat_production_w_m3_at(substance: String, years: float) -> float:
	var rho: float = float(LASubstances.table().get(substance, {}).get("density", 0.0))
	return heat_production_w_kg_at(substance, years) * rho


## Present-epoch watts per kg of rock from one nuclide.
static func _w_per_kg(kg_per_kg: float, half_life_years: float, j_per_decay: float,
		molar_mass: float) -> float:
	if half_life_years <= 0.0 or molar_mass <= 0.0:
		return 0.0
	var lambda_per_s: float = log(2.0) / (half_life_years * PC.SECONDS_PER_YEAR)
	var atoms: float = (kg_per_kg / molar_mass) * PC.AVOGADRO_PER_MOL
	return lambda_per_s * atoms * j_per_decay
