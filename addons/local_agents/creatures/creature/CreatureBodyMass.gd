class_name LACreatureBodyMass
extends RefCounted


const RESERVE_FRAC: float = 0.20       # labile reserve (fat + glycogen) as a fraction of live mass, wild mammal
const LETHAL_WATER_DEFICIT_FRAC: float = 0.15   # water a mammal can lose as a fraction of live mass before death

const MASS_UNIT_SCALE: float = 1.0e-4  # fauna:flora scale factor applied to TISSUE_PER_KG
const TISSUE_PER_KG: float = 130.0 * MASS_UNIT_SCALE      # simulation mass units per kilogram of live tissue
const REFERENCE_MASS_KG: float = 0.5   # fallback when a species has no measured mass yet (a small mammal)


## Species body mass in kilograms — the one measured number the rest of this module derives from.
static func mass_kg(config: Dictionary) -> float:
	return maxf(float(config.get("mass_kg", REFERENCE_MASS_KG)), 1.0e-7)


## Whole live mass in simulation units — structural tissue plus the labile reserve plus anything in the gut.
static func live_mass(config: Dictionary) -> float:
	return TISSUE_PER_KG * mass_kg(config)


static func reserve(config: Dictionary) -> float:
	return live_mass(config) * RESERVE_FRAC


## Non-labile tissue: bone, muscle, organ.
static func structural(config: Dictionary) -> float:
	return live_mass(config) * (1.0 - RESERVE_FRAC)


static func hydration_capacity(config: Dictionary) -> float:
	return live_mass(config) * LETHAL_WATER_DEFICIT_FRAC


## Water turnover per second.
const WATER_PER_CAPACITY: float = 1.5
static func thirst_rate(c) -> float:
	return WATER_PER_CAPACITY * LACreatureRespiration.capacity_rate(c)


const BITE_OVER_CAPACITY: float = 12.0   # a feeding animal ingests up to this multiple of its aerobic capacity
static func bite_rate(c) -> float:
	return LACreatureRespiration.capacity_rate(c) * BITE_OVER_CAPACITY


const FOUNDING_FRAMES: int = 60


static func note_spawn(c, from_genome: bool) -> void:
	if from_genome or c == null or c._material == null:
		return
	if not c._material.has_method("note_biota_spawn"):
		return
	c._material.note_biota_spawn(body_mass(c), int(Engine.get_physics_frames()) <= FOUNDING_FRAMES)


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
	c.food_value = body_mass(c)


static func body_mass(c) -> float:
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


## Put `amount` of digested mass into structural tissue, returning what was used.
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
	c.food_value = body_mass(c)


## Keep `food_value` in step with what the body actually weighs.
static func tick(c) -> void:
	c.food_value = body_mass(c)
