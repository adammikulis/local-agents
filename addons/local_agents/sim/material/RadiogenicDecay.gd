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


## nuclide -> [kg of nuclide per kg of rock today, half-life years, decay energy J per decay,
## molar mass, atoms of each daughter per decay]. Decay conserves nucleons: the parent's mass number
## lands in the daughters (238 = 206 + 8 x 4), and K40 splits by its measured branching.
static func nuclides(traces: Dictionary) -> Dictionary:
	var u: float = float(traces.get("U", 0.0))
	var th: float = float(traces.get("Th", 0.0))
	var k: float = float(traces.get("K", 0.0))
	return {
		"U238":  [u * PC.ISOTOPE_FRAC_U238, PC.HALF_LIFE_U238_YEARS,
			PC.DECAY_ENERGY_U238_MEV * PC.MEV_J, PC.MOLAR_MASS_U238_KG_MOL,
			{"Pb": 1.0, "He": 8.0}],
		"U235":  [u * PC.ISOTOPE_FRAC_U235, PC.HALF_LIFE_U235_YEARS,
			PC.DECAY_ENERGY_U235_MEV * PC.MEV_J, PC.MOLAR_MASS_U235_KG_MOL,
			{"Pb": 1.0, "He": 7.0}],
		"TH232": [th * PC.ISOTOPE_FRAC_TH232, PC.HALF_LIFE_TH232_YEARS,
			PC.DECAY_ENERGY_TH232_MEV * PC.MEV_J, PC.MOLAR_MASS_TH232_KG_MOL,
			{"Pb": 1.0, "He": 6.0}],
		"K40":   [k * PC.ISOTOPE_FRAC_K40, PC.HALF_LIFE_K40_YEARS,
			PC.DECAY_ENERGY_K40_MEV * PC.MEV_J, PC.MOLAR_MASS_K40_KG_MOL,
			{"Ca": PC.K40_BETA_FRAC, "Ar": PC.K40_EC_FRAC}],
	}


## Watts per kilogram of a rock carrying `traces`, `years` after the present epoch.
static func heat_w_kg_of(traces: Dictionary, years: float) -> float:
	var w: float = 0.0
	for row in nuclides(traces).values():
		w += _w_per_kg(row[0], row[1], row[2], row[3]) * pow(2.0, -years / float(row[1]))
	return w


## Moles of each daughter element accumulated per kg of rock between the planet's formation and `years`.
static func daughters_mol_per_kg(traces: Dictionary, years: float) -> Dictionary:
	var out: Dictionary = {}
	var t0: float = -PC.EARTH_FORMATION_AGE_YEARS
	for row in nuclides(traces).values():
		var n_today: float = float(row[0]) / float(row[3])
		var hl: float = float(row[1])
		var decayed: float = n_today * (pow(2.0, -t0 / hl) - pow(2.0, -years / hl))
		if decayed <= 0.0:
			continue
		for el in row[4]:
			out[el] = float(out.get(el, 0.0)) + decayed * float(row[4][el])
	return out


## Present-epoch watts per kg of rock from one nuclide.
static func _w_per_kg(kg_per_kg: float, half_life_years: float, j_per_decay: float,
		molar_mass: float) -> float:
	if half_life_years <= 0.0 or molar_mass <= 0.0:
		return 0.0
	var lambda_per_s: float = log(2.0) / (half_life_years * PC.SECONDS_PER_YEAR)
	var atoms: float = (kg_per_kg / molar_mass) * PC.AVOGADRO_PER_MOL
	return lambda_per_s * atoms * j_per_decay
