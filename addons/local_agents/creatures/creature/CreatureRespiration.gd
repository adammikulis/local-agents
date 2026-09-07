class_name LACreatureRespiration
extends RefCounted


const SPHERE_AREA_COEFF: float = 4.835976   # (36π)^(1/3): surface of a sphere per V^(2/3)

# KLEIBER'S LAW (Kleiber 1932, Hilgardia 6:315): basal metabolic rate is 70 kcal/day at one kilogram and
# rises with the three-quarter power of mass.
const KLEIBER_BASAL_KCAL_PER_DAY: float = 70.0
const KLEIBER_EXPONENT: float = 0.75
const KCAL_J: float = 4184.0                # thermochemical kilocalorie
const BASAL_W_AT_1KG: float = KLEIBER_BASAL_KCAL_PER_DAY * KCAL_J \
	/ LACreatureBodyMass.SECONDS_PER_DAY

## Peterson, Nagy & Diamond 1990 (PNAS 87:2324): the sustained metabolic scope of a free-living animal,
## the ceiling it can hold for days.
const SUSTAINED_SCOPE: float = 7.0
## Weibel & Hoppeler 2005, J. Exp. Biol. 208:1635: factorial aerobic scope, VO2max over basal.
const MAX_AEROBIC_SCOPE: float = 10.0
## Summit (cold-induced maximum) metabolism over basal in a small mammal — Schmidt-Nielsen 1997, Animal
## Physiology: Adaptation and Environment, 5th ed., ch.7.
const SUMMIT_OVER_BASAL: float = 5.0

## Whole-body specific heat of mammalian soft tissue, J/(kg·K): Cooper & Trezek 1971, Aerosp. Med. 42:24.
const TISSUE_SPECIFIC_HEAT_J_KGK: float = 3470.0

## Henry solubility of O2 in water at 298 K, mol/(m^3·Pa): Sander 2015, Atmos. Chem. Phys. 15:4399.
const O2_HENRY_MOL_M3_PA: float = 1.3e-5

const DEFICIT_HP_FRAC: float = 1.0 / 30.0

const THERMAL_TAU_K: float = 5.1318       # tau (sec) = THERMAL_TAU_K * body_mass_kg / exchange_area

## Half-width in °C of the envelope where liquid cell water and intact protein overlap.
static func envelope_half_c() -> float:
	return (LAPhysical.PROTEIN_DENATURE_C - LAPhysical.WATER_FREEZE_C) * 0.5


## This genome's optimum in °C (`thermal_optimum_c` locus).
static func band_optimum_c(c) -> float:
	return float(c.get("thermal_optimum_c"))


## This genome's half-width in °C: `thermal_tolerance` as a fraction of the envelope's half-range.
static func band_width_c(c) -> float:
	return clampf(float(c.get("thermal_tolerance")), 0.0, 1.0) * envelope_half_c()


## The reaction-rate factor at body temperature `t` for THIS creature.
static func temp_band(t: float, c) -> float:
	var w: float = band_width_c(c)
	if w <= 0.0:
		return 0.0
	var d: float = (t - band_optimum_c(c)) / w
	return maxf(0.0, 1.0 - d * d)


## Body mass in KILOGRAMS.
static func body_mass(c) -> float:
	return maxf(float(c.get("mass_kg")), 1.0e-7)


## The body's characteristic linear dimension, in metres.
static func body_length(m_kg: float) -> float:
	return pow(maxf(m_kg, 1.0e-9) / LAPhysical.ANIMAL_TISSUE_DENSITY_KG_M3, 1.0 / 3.0)


static func exchange_area(c) -> float:
	var l: float = body_length(body_mass(c))
	return SPHERE_AREA_COEFF * l * l * maxf(float(c.get("respiratory_capacity")), 0.0)


## Joules released per mole of body carbon oxidised: the same organic-carbon-to-CO2 enthalpy the biota
## seam books the exchange with, so the body's watts and the field's moles are one arithmetic.
static func carbon_j_per_mol() -> float:
	var j: float = LAMaterialFieldBiota3D._respiration_j_per_o2_unit()
	if j <= 0.0:
		push_error("LACreatureRespiration: the substance table declares no oxidation enthalpy for body carbon.")
	return j


## Basal metabolic rate in WATTS at this body mass, by Kleiber's law.
static func basal_watts(m_kg: float) -> float:
	return BASAL_W_AT_1KG * pow(maxf(m_kg, 1.0e-9), KLEIBER_EXPONENT)


## The basal rate as moles of body carbon oxidised per second — the floor this body must produce to live.
static func basal_carbon_rate(c) -> float:
	var j: float = carbon_j_per_mol()
	return 0.0 if j <= 0.0 else basal_watts(body_mass(c)) / j


## The rate this body can hold for days: what its mouth is sized to supply.
static func sustained_carbon_rate(c) -> float:
	return basal_carbon_rate(c) * SUSTAINED_SCOPE * maxf(float(c.get("respiratory_capacity")), 0.0)


## Moles of O2 per cubic metre in this animal's own medium at saturation: air at one atmosphere, or the
## water in equilibrium with that air by Henry's law.
static func medium_o2_mol_m3(c) -> float:
	if String(c.get("breathes")) == "water":
		return O2_HENRY_MOL_M3_PA * LAPhysical.AIR_MOLE_FRAC_O2 * LAPhysical.STANDARD_PRESSURE_PA
	return LAPhysical.AIR_MOLE_FRAC_O2 * LAPhysical.STP_MOLAR_DENSITY_MOL_M3


## Fick's law across the exchange surface: uptake is proportional to what the medium holds, and an animal
## evolved in its own saturated medium, so nothing above saturation buys it any more.
static func o2_saturation(c, o2_mol_m3: float) -> float:
	var full: float = medium_o2_mol_m3(c)
	return 0.0 if full <= 0.0 else clampf(o2_mol_m3 / full, 0.0, 1.0)


## The most carbon this body can oxidise a second in the oxygen it is standing in, at its body temperature.
static func aerobic_ceiling(c, o2_mol_m3: float, band: float) -> float:
	return basal_carbon_rate(c) * MAX_AEROBIC_SCOPE * maxf(float(c.get("respiratory_capacity")), 0.0) \
		* o2_saturation(c, o2_mol_m3) * band


## Kelvin of body warming per mole of carbon oxidised, per kilogram of body.
static func metabolic_heat_k_per_mol_kg() -> float:
	return carbon_j_per_mol() / TISSUE_SPECIFIC_HEAT_J_KGK


## Advance body temperature, then run the oxidation.
static func tick(c, pos: Vector3, delta: float) -> bool:
	if delta <= 0.0:
		return false
	var evo: float = LAAblate.evo_fast()
	var mass: float = body_mass(c)
	var area: float = exchange_area(c)
	if mass <= 0.0 or area <= 0.0:
		return false

	# A cell holding no matter is no medium: nothing touches the skin, so nothing carries heat off it.
	var ambient: float = c._material.temp_at(pos) if c._material != null else NAN
	if not is_nan(ambient):
		var tau: float = maxf(THERMAL_TAU_K * mass / area, 0.001)
		var k: float = clampf(delta * evo / tau, 0.0, 1.0)     # clamped: a large step relaxes fully, never overshoots
		c.body_temp = float(c.body_temp) + (ambient - float(c.body_temp)) * k

	var band: float = temp_band(float(c.body_temp), c)
	var cold: float = clampf((band_optimum_c(c) - float(c.body_temp)) / maxf(band_width_c(c), 0.001), 0.0, 1.0)
	var gain: float = 1.0 + (SUMMIT_OVER_BASAL - 1.0) * clampf(float(c.get("thermogenesis")), 0.0, 1.0) * cold
	var exertion: float = 1.0
	if c.state == "flee" or c.state == "panic" or c.state == "chase":
		exertion = 1.6
	elif c.state == "sleep" or c.state == "rest" or c.state == "roost":
		exertion = 0.5                        # resting lowers demand — why animals do it
	var o2: float = breathable_o2(c, pos)
	var basal: float = basal_carbon_rate(c)
	# What the body asks for, and what its lungs and its medium will let it have.
	var ceiling: float = aerobic_ceiling(c, o2, band)
	var rate: float = minf(basal * gain * exertion, ceiling)
	var want: float = rate * delta * evo
	want = minf(want, maxf(float(c.energy), 0.0))          # cannot oxidise fuel that is not there
	# Hand the transaction to the substrate.
	var extent: float = want
	if c._material != null:
		extent = c._material.respire_at(pos, want)
		if extent < want:
			extent += LAFakes.draw("breathable_o2", want - extent)
	c.energy -= extent
	c._resp_rate = extent / maxf(delta * evo, 1e-6)
	c._resp_capacity = ceiling
	c.energy -= LAAppraisal.display_upkeep(c, delta) * evo

	c.body_temp = float(c.body_temp) + extent * metabolic_heat_k_per_mol_kg() / mass

	if ceiling < basal and basal > 0.0:
		# The shortfall as a FRACTION of the requirement (0 = met, 1 = producing nothing at all).
		var shortfall: float = clampf((basal - ceiling) / basal, 0.0, 1.0)
		c.health -= shortfall * DEFICIT_HP_FRAC * float(c.max_health) * delta * evo
		if c.health <= 0.0:
			c.die(deficit_cause(c, o2))
			return true
	if c.energy <= 0.0:
		c.die("starvation")
		return true
	return false


## Moles of O2 per cubic metre at this animal's head. The seeded 4.4 Ga air holds none, so while the
## `breathable_o2` stand-in is in force open air holds what today's air holds — but only open air: a
## submerged lung reads the water it is drowning in, which no stand-in fills.
static func breathable_o2(c, pos: Vector3) -> float:
	if c._material == null:
		return medium_o2_mol_m3(c) if LAFakes.stands_in("breathable_o2") else 0.0
	var up: Vector3 = c.terrain.up_at(pos) if c.terrain != null and c.terrain.has_method("up_at") else Vector3.UP
	var head: Vector3 = pos + up * c.size
	var submerged: bool = c._material.is_submerged_at(head.x, head.y, head.z)
	if c.breathes == "water":
		if not submerged:
			return 0.0
		var dissolved: float = c._material.o2_at(head.x, head.y, head.z)
		if dissolved <= 0.0 and LAFakes.stands_in("breathable_o2"):
			return medium_o2_mol_m3(c)
		return dissolved
	if submerged:
		# A lung under water still runs on the air in it, and on nothing once that is gone.
		return medium_o2_mol_m3(c) if float(c._breath) > 0.0 else 0.0
	var air: float = c._material.breathable_o2_at(head.x, head.y, head.z)
	if air <= 0.0 and LAFakes.stands_in("breathable_o2"):
		return medium_o2_mol_m3(c)
	return air


static func deficit_cause(c, o2: float) -> String:
	if float(c.body_temp) >= LAPhysical.PROTEIN_DENATURE_C:
		return "hyperthermia"
	if float(c.body_temp) <= LAPhysical.WATER_FREEZE_C:
		return "hypothermia"
	if o2 <= 0.0:
		# A lung-breather that has run out of oxygen while submerged drowned.
		if c._material != null and c.breathes != "water":
			var up: Vector3 = c.terrain.up_at(c.global_position) if c.terrain != null and c.terrain.has_method("up_at") else Vector3.UP
			if c._material.is_submerged_at(c.global_position.x + up.x * c.size,
					c.global_position.y + up.y * c.size, c.global_position.z + up.z * c.size):
				return "drowned"
		return "suffocated"
	# Body temp inside the envelope, outside this genome's band. Fuel exhaustion is a separate death.
	return "thermal_stress"
