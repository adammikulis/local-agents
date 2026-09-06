class_name LACreatureBodyMass
extends RefCounted


# WHAT A VERTEBRATE BODY IS MADE OF, as fractions of live (wet) mass. Species body mass in kilograms is the
# one measured number; every stock below is that mass read through this composition.
const BODY_WATER_FRAC: float = 0.70    # Peters 1983, The Ecological Implications of Body Size, ch.2
const DRY_CARBON_FRAC: float = 0.45    # Sterner & Elser 2002, Ecological Stoichiometry, ch.3
const RESERVE_FRAC: float = 0.20       # fat + glycogen, Pond 1978, Ann. Rev. Ecol. Syst. 9:519
const LETHAL_WATER_DEFICIT_FRAC: float = 0.15   # water lost at death, Adolph 1947, Physiology of Man in the Desert

## Moles of body carbon per kilogram of live tissue: the unit the field's biomass channel is counted in.
const CARBON_MOL_PER_KG: float = (1.0 - BODY_WATER_FRAC) * DRY_CARBON_FRAC \
	/ LAPhysical.MOLAR_MASS_CARBON_KG_MOL
## Moles of body water per kilogram of live tissue.
const WATER_MOL_PER_KG: float = BODY_WATER_FRAC / LAPhysical.MOLAR_MASS_WATER_KG_MOL

const REFERENCE_MASS_KG: float = 0.5   # fallback when a species has no measured mass yet (a small mammal)


## Species body mass in kilograms — the one measured number the rest of this module derives from.
static func mass_kg(config: Dictionary) -> float:
	return maxf(float(config.get("mass_kg", REFERENCE_MASS_KG)), 1.0e-7)


## Whole-body carbon in MOLES: structural tissue plus the labile reserve plus anything in the gut.
static func live_carbon(config: Dictionary) -> float:
	return CARBON_MOL_PER_KG * mass_kg(config)


static func reserve(config: Dictionary) -> float:
	return live_carbon(config) * RESERVE_FRAC


## Non-labile tissue: bone, muscle, organ.
static func structural(config: Dictionary) -> float:
	return live_carbon(config) * (1.0 - RESERVE_FRAC)


## Body water a mammal may lose before it dies, in MOLES of H2O.
static func hydration_capacity(config: Dictionary) -> float:
	return LETHAL_WATER_DEFICIT_FRAC * mass_kg(config) / LAPhysical.MOLAR_MASS_WATER_KG_MOL


## Total body water, moles of H2O. The store above is the losable part of it.
static func body_water(config: Dictionary) -> float:
	return WATER_MOL_PER_KG * mass_kg(config)


## A mammal cycles about a tenth of its body mass in water a day (Nagy & Peterson 1988, Univ. Calif. Publ.
## Zool. 120) and dies having lost LETHAL_WATER_DEFICIT_FRAC of it, so a full store is that fraction over
## this turnover, in seconds.
const WATER_TURNOVER_PER_DAY: float = 0.1
const SECONDS_PER_DAY: float = LAPhysical.SECONDS_PER_YEAR / 365.25
static func thirst_rate(c) -> float:
	return float(c.max_hydration) * WATER_TURNOVER_PER_DAY / (LETHAL_WATER_DEFICIT_FRAC * SECONDS_PER_DAY)


## Moles of carbon a mouth takes a second while it is feeding. What caps a sustained energy budget is the
## alimentary tract, not the muscle (Hammond & Diamond 1997, Nature 386:457), so the mouth is sized by the
## rate the body can sustain over the fraction of it the gut assimilates.
static func bite_rate(c) -> float:
	return LACreatureRespiration.sustained_carbon_rate(c) / LACreatureDigestion.BASE_EFFICIENCY


## Every body that appears is booked, whoever made it: the seal decides whether it is seeded matter or a
## stand-in's, not a frame count.
static func note_spawn(c) -> void:
	if c == null or c._material == null or not c._material.has_method("note_biota_spawn"):
		return
	c._material.note_biota_spawn(body_carbon(c))


## Overwrite the mass-derived fields on a freshly-configured creature.
static func apply(c, config: Dictionary) -> void:
	c.mass_kg = mass_kg(config)
	c.structural_mass = structural(config)
	# A config override on the reserve is still honoured for tests and set-pieces; nothing in the roster sets it.
	c.max_energy = float(config.get("max_energy", reserve(config)))
	c.energy = c.max_energy
	c.max_hydration = hydration_capacity(config)
	c.hydration = c.max_hydration
	# These two read the CREATURE (they need its expressed `respiratory_capacity` gene as well as its mass).
	c.thirst_rate = thirst_rate(c)
	c.bite_rate = bite_rate(c)
	c.food_value = body_carbon(c)


## Moles of carbon this body is carrying right now.
static func body_carbon(c) -> float:
	if c == null:
		return 0.0
	return maxf(0.0, float(c.structural_mass) + maxf(0.0, float(c.energy))
		+ maxf(0.0, float(c.gut)) + maxf(0.0, float(c.gut_waste)))


static func draw(c, want: float) -> float:
	if c == null or want <= 0.0:
		return 0.0
	var taken: float = 0.0
	var from_gut: float = minf(want, maxf(0.0, float(c.gut)))
	c.gut -= from_gut
	taken += from_gut
	var from_energy: float = minf(want - taken, maxf(0.0, float(c.energy)))
	c.energy -= from_energy
	taken += from_energy
	var from_tissue: float = minf(want - taken, maxf(0.0, float(c.structural_mass)))
	c.structural_mass -= from_tissue
	taken += from_tissue
	return taken


## Mass as a fraction of the adult body, from the age-driven growth curve.
static func growth_mass_fraction(c) -> float:
	var s: float = LACreatureLifeStage.growth_scale(c)
	return s * s * s


## Structural tissue this body should carry at its current age.
static func growth_target_structural(c) -> float:
	return structural(c.config) * growth_mass_fraction(c)


## How much tissue this body still has to build. Zero once grown, or if it is already over target.
static func growth_deficit(c) -> float:
	return maxf(0.0, growth_target_structural(c) - float(c.structural_mass))


## Put `amount` of digested carbon into structural tissue, returning what was used.
static func grow(c, amount: float) -> float:
	var used: float = minf(maxf(amount, 0.0), growth_deficit(c))
	c.structural_mass += used
	return used


## Size a newborn to its age.
static func size_to_age(c) -> void:
	var f: float = growth_mass_fraction(c)
	c.structural_mass = structural(c.config) * f
	c.max_energy = reserve(c.config) * f
	c.energy = c.max_energy
	c.max_hydration = hydration_capacity(c.config) * f
	c.hydration = c.max_hydration
	c.thirst_rate = thirst_rate(c)
	c.food_value = body_carbon(c)


## Keep `food_value` in step with what the body actually weighs.
static func tick(c) -> void:
	c.food_value = body_carbon(c)
