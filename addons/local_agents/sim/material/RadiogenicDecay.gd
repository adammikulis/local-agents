class_name LARadiogenicDecay
extends RefCounted

const PC: GDScript = preload("res://addons/local_agents/sim/material/PhysicalConstants.gd")

## nuclide -> [kg of nuclide per kg of rock TODAY, half-life years, decay energy J per decay, molar mass].
static func nuclides() -> Dictionary:
	return {
		"U238":  [PC.BSE_U_KG_PER_KG * PC.ISOTOPE_FRAC_U238, PC.HALF_LIFE_U238_YEARS,
			PC.DECAY_ENERGY_U238_MEV * PC.MEV_J, PC.MOLAR_MASS_U238_KG_MOL],
		"U235":  [PC.BSE_U_KG_PER_KG * PC.ISOTOPE_FRAC_U235, PC.HALF_LIFE_U235_YEARS,
			PC.DECAY_ENERGY_U235_MEV * PC.MEV_J, PC.MOLAR_MASS_U235_KG_MOL],
		"TH232": [PC.BSE_TH_KG_PER_KG * PC.ISOTOPE_FRAC_TH232, PC.HALF_LIFE_TH232_YEARS,
			PC.DECAY_ENERGY_TH232_MEV * PC.MEV_J, PC.MOLAR_MASS_TH232_KG_MOL],
		"K40":   [PC.BSE_K_KG_PER_KG * PC.ISOTOPE_FRAC_K40, PC.HALF_LIFE_K40_YEARS,
			PC.DECAY_ENERGY_K40_MEV * PC.MEV_J, PC.MOLAR_MASS_K40_KG_MOL],
	}


## Watts per kilogram of rock, `years` after the present epoch; negative reaches into the past.
static func heat_production_w_kg_at(years: float) -> float:
	var w: float = 0.0
	for row in nuclides().values():
		w += _w_per_kg(row[0], row[1], row[2], row[3]) * pow(2.0, -years / float(row[1]))
	return w


## Kilograms of `nuclide` per kilogram of rock remaining `years` after the present epoch.
static func remaining_kg_per_kg(nuclide: String, years: float) -> float:
	var row: Array = nuclides().get(nuclide, [])
	if row.is_empty():
		return 0.0
	return float(row[0]) * pow(2.0, -years / float(row[1]))


## Kilograms of parent nuclide consumed per kilogram of rock over `dt_years` ending at `years`.
static func consumed_kg_per_kg(nuclide: String, years: float, dt_years: float) -> float:
	return maxf(0.0, remaining_kg_per_kg(nuclide, years) - remaining_kg_per_kg(nuclide, years + dt_years))


## Present-epoch watts per kg of rock from one nuclide.
static func _w_per_kg(kg_per_kg: float, half_life_years: float, j_per_decay: float,
		molar_mass: float) -> float:
	if half_life_years <= 0.0 or molar_mass <= 0.0:
		return 0.0
	var lambda_per_s: float = log(2.0) / (half_life_years * PC.SECONDS_PER_YEAR)
	var atoms: float = (kg_per_kg / molar_mass) * PC.AVOGADRO_PER_MOL
	return lambda_per_s * atoms * j_per_decay
