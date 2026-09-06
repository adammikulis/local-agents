extends SceneTree

## A BODY'S PHYSIOLOGY IS ITS MASS READ THROUGH PUBLISHED LAWS. Every bound below is a measured fact
## about real animals, written here independently of the code it checks, so a disagreement names which
## claim broke rather than restating the constant it was read from.

# A vertebrate is 11-19 % carbon by wet mass: about 70 % water, and 40-50 % of the dry remainder carbon.
const CARBON_MOL_PER_KG_LO: float = 0.11 / 0.012011
const CARBON_MOL_PER_KG_HI: float = 0.19 / 0.012011
# A mammal dies having lost 10-20 % of its body mass as water.
const WATER_MOL_PER_KG_LO: float = 0.10 / 0.018015
const WATER_MOL_PER_KG_HI: float = 0.20 / 0.018015
# Kleiber 1932: 70 kcal a day at one kilogram, rising on the three-quarter power of mass.
const KLEIBER_W_AT_1KG: float = 70.0 * 4184.0 / 86400.0
const KLEIBER_EXPONENT: float = 0.75
const REL_BOUND: float = 0.01
# Oxidising a mole of organic carbon to CO2 releases 0.39-0.48 MJ.
const CARBON_J_PER_MOL_LO: float = 3.9e5
const CARBON_J_PER_MOL_HI: float = 4.8e5
# Sea-level air holds 8-10 mol of O2 per cubic metre; water in equilibrium with it, 0.2-0.4.
const AIR_O2_LO: float = 8.0
const AIR_O2_HI: float = 10.0
const WATER_O2_LO: float = 0.2
const WATER_O2_HI: float = 0.4
# A fasting animal lives on its labile reserve for hours (an insect) to weeks (a large mammal).
const FAST_DAYS_LO: float = 0.1
const FAST_DAYS_HI: float = 60.0
# Free-living intake covers 2-3 times basal (Nagy 1987) and cannot exceed the sustained ceiling near
# seven times it (Peterson, Nagy & Diamond 1990), over an assimilation efficiency below one.
const MOUTH_OVER_BASAL_LO: float = 2.0
const MOUTH_OVER_BASAL_HI: float = 15.0
# An animal takes its whole daily water in one bout of between a minute and an hour.
const DRINK_BOUT_S_LO: float = 60.0
const DRINK_BOUT_S_HI: float = 3600.0
const SECONDS_PER_DAY: float = 86400.0


## A bare body carrying only the fields the physiology reads: no scene, no field, no genome.
class Body extends RefCounted:
	var mass_kg: float = 1.0
	var breathes: String = "air"
	var respiratory_capacity: float = 1.0
	var thermogenesis: float = 0.0
	var max_hydration: float = 0.0
	var thirst_rate: float = 0.0


var _fails: Array[String] = []


func _band(what: String, got: float, lo: float, hi: float) -> void:
	if not is_finite(got) or got < lo or got > hi:
		_fails.append("%s is %s, outside the measured %s..%s" % [what, got, lo, hi])


func _init() -> void:
	var j: float = LACreatureRespiration.carbon_j_per_mol()
	_band("the oxidation enthalpy of body carbon, J/mol", j, CARBON_J_PER_MOL_LO, CARBON_J_PER_MOL_HI)

	# KLEIBER, INDEPENDENTLY RESTATED: the rate at one kilogram and the exponent it rises on.
	var w1: float = LACreatureRespiration.basal_watts(1.0)
	if absf(w1 - KLEIBER_W_AT_1KG) > REL_BOUND * KLEIBER_W_AT_1KG:
		_fails.append("basal_watts(1 kg) is %s W, not Kleiber's %s W" % [w1, KLEIBER_W_AT_1KG])
	var ratio: float = LACreatureRespiration.basal_watts(100.0) / maxf(w1, 1.0e-30)
	var want_ratio: float = pow(100.0, KLEIBER_EXPONENT)
	if absf(ratio - want_ratio) > REL_BOUND * want_ratio:
		_fails.append("basal rate rises %s-fold over a hundredfold mass, not Kleiber's %s"
			% [ratio, want_ratio])

	var lung: Body = Body.new()
	var gill: Body = Body.new()
	gill.breathes = "water"
	_band("moles of O2 per m^3 in the air a lung breathes",
		LACreatureRespiration.medium_o2_mol_m3(lung), AIR_O2_LO, AIR_O2_HI)
	_band("moles of O2 per m^3 in the water a gill breathes",
		LACreatureRespiration.medium_o2_mol_m3(gill), WATER_O2_LO, WATER_O2_HI)

	# THE WHOLE ROSTER, one species at a time. Nothing checked here is a per-species number, so a row
	# outside a band is the law being wrong at that mass.
	var roster: Array = _roster()
	if roster.is_empty():
		printerr("CREATURE_ENERGY: the species library declares no body mass, so nothing was checked.")
		quit(2)
		return
	for row in roster:
		_check_species(String(row["species"]), float(row["mass_kg"]))

	print("CREATURE_ENERGY={\"species\":%d,\"failures\":%d}" % [roster.size(), _fails.size()])
	for f in _fails:
		printerr("  " + f)
	quit(1 if _fails.size() > 0 else 0)


func _check_species(name: String, m: float) -> void:
	var cfg: Dictionary = {"mass_kg": m}
	_band("%s: moles of body carbon per kg" % name,
		LACreatureBodyMass.live_carbon(cfg) / m, CARBON_MOL_PER_KG_LO, CARBON_MOL_PER_KG_HI)
	_band("%s: moles of losable body water per kg" % name,
		LACreatureBodyMass.hydration_capacity(cfg) / m, WATER_MOL_PER_KG_LO, WATER_MOL_PER_KG_HI)
	var body: Body = Body.new()
	body.mass_kg = m
	var basal: float = LACreatureRespiration.basal_carbon_rate(body)
	if basal <= 0.0:
		_fails.append("%s: the basal rate is not positive, so this body oxidises nothing" % name)
		return
	# THE CARBON AND THE BURN ARE ONE SYSTEM, and their ratio is how long the animal can fast. A body
	# carbon in any unit but moles reads here as an animal that starves in seconds or never.
	_band("%s: days a full reserve feeds the basal rate" % name,
		LACreatureBodyMass.reserve(cfg) / basal / SECONDS_PER_DAY, FAST_DAYS_LO, FAST_DAYS_HI)
	_band("%s: mouth rate over basal rate" % name,
		LACreatureBodyMass.bite_rate(body) / basal, MOUTH_OVER_BASAL_LO, MOUTH_OVER_BASAL_HI)
	body.max_hydration = LACreatureBodyMass.hydration_capacity(cfg)
	body.thirst_rate = LACreatureBodyMass.thirst_rate(body)
	var day_water: float = LACreatureBodyMass.WATER_TURNOVER_PER_DAY * m \
		/ LAPhysical.MOLAR_MASS_WATER_KG_MOL
	_band("%s: seconds to drink a day's water" % name,
		day_water / maxf(LACreatureThirst.drink_rate(body), 1.0e-30), DRINK_BOUT_S_LO, DRINK_BOUT_S_HI)


## Every species file's declared body mass. The roster is the input; nothing else about it is read.
func _roster() -> Array:
	var out: Array = []
	for kind in LASpeciesLibrary.known_kinds():
		var cfg: Dictionary = LASpeciesLibrary.load_config(String(kind))
		if cfg.has("mass_kg"):
			out.append({"species": String(kind), "mass_kg": float(cfg["mass_kg"])})
	return out
