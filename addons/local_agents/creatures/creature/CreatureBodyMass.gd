class_name LACreatureBodyMass
extends RefCounted

## LACreatureBodyMass — THE MASS LEDGER OF A BODY. One measured mass per species, one unit, and every
## transaction a body makes with the world measured in it.
##
## THIS MODULE OWNS THE ACCOUNT, NOT THE RATE LAW. The rate law is LACreatureRespiration: a body burns what its
## gas-exchange SURFACE and the local oxygen can support, so metabolic rate emerges as M^(2/3) from geometry
## with no exponent typed anywhere. What lives here is everything that has to be a MASS for the substrate's
## books to close — live mass, the labile reserve, structural tissue, what a predator can draw out of a body,
## and what a body weighed when it spawned.
##
## WHY THAT SPLIT EXISTS, AND WHAT IT REPLACED. Two branches replaced the old physiology at the same time. One
## derived body mass from the `size` gene and scaled the burn as Rubner M^(2/3); the other took a measured
## per-species `mass_kg` and scaled the burn as Kleiber M^(3/4) with declared endotherm/ectotherm strategies.
## The composite keeps the emergent surface law and takes the measured masses:
##   * KLEIBER'S M^0.75 IS NOT ASSERTED HERE. West, Brown & Enquist (1997) explain it as a consequence of a
##     space-filling fractal delivery network with size-invariant terminal units — branching vasculature,
##     capillaries, alveoli. This substrate has none of that: a body is one point with one exchange surface.
##     Typing 0.75 in would encode the conclusion of a theory whose mechanism is absent. If that machinery is
##     ever built, 0.75 must be allowed to EMERGE. Read the fitted exponent in SIM_REPORT (`metab_exponent`).
##   * THE MEASURED MASSES ARE KEPT, because a body mass is a fact about an animal. `size` is the visual and
##     collision scale and the roster compresses it hard (ant 0.08 against villager 1.0, where the real ratio
##     is nearer 0.003), so deriving mass from it imported a rendering decision into the physics and made an
##     ant weigh 36 grams. `mass_kg` is its own species field and the two are independent on purpose.
##   * ENDOTHERM AND ECTOTHERM ARE NOT A CATEGORY here. There is no `thermal_strategy` and no `BASAL_SCALE`
##     table. The heritable, continuous `thermogenesis` gene is how hard a body raises its oxygen throughput
##     when it falls below its own enzyme optimum; at 0 the term vanishes identically and the animal IS an
##     ectotherm, by arithmetic rather than by a branch. Ancestrally 0; birds and mammals declare it.
##
## WHICH CONSTANTS ARE FACTS AND WHICH ARE UNITS, stated because this repo has been burned by the difference.
##   * `RESERVE_FRAC` and `LETHAL_WATER_DEFICIT_FRAC` are measured properties of animals.
##   * `TISSUE_PER_KG` is a UNIT CONVERSION — the simulation's mass unit has no kilogram value of its own, so
##     something has to define one, and this does. Moving it rescales the whole fauna against the planet's
##     standing crop; it is not a physiological knob and no timescale depends on it.
##
## Static + dynamic field access on the passed creature, like the other Creature* helpers.
## (Explicit types only, no ':=' inferred typing.)

# --- MEASURED PROPERTIES OF ANIMALS (facts; not tuning knobs) ---------------------------------------------
const RESERVE_FRAC: float = 0.20       # labile reserve (fat + glycogen) as a fraction of live mass, wild mammal
## `max_hydration` is the LETHAL WATER DEFICIT, not total body water. An animal is dead long before its tissue
## is dry: losing about 15% of body mass as water is fatal in a mammal, while total body water is ~65% of mass.
const LETHAL_WATER_DEFICIT_FRAC: float = 0.15

# --- THE UNIT (what one simulation mass unit means; see the header) ----------------------------------------
#
# ONE MASS UNIT IS THE FIELD'S MASS UNIT, and that is not a cosmetic choice — it is what makes conservation
# across the body/field boundary mean anything at all. An animal's mass is debited out of the `biomass`
# channel when it grazes and credited into `detritus` when it dies, so a creature "mass unit" and a field
# "mass unit" have to be the same thing or the ledger is comparing apples to nothing.
#
# THE SCALE IS SET BY THE REAL FAUNA:FLORA RATIO. Global animal biomass is about 2 Gt of carbon against about
# 450 Gt for plants. The scale below holds the founding fauna to a small share of the planet's standing crop
# and of the hydrosphere, erring generous next to the real ratio because primary production here is
# nutrient-limited.
const MASS_UNIT_SCALE: float = 1.0e-4  # fauna:flora scale factor applied to TISSUE_PER_KG
const TISSUE_PER_KG: float = 130.0 * MASS_UNIT_SCALE      # simulation mass units per kilogram of live tissue
const REFERENCE_MASS_KG: float = 0.5   # fallback when a species has no measured mass yet (a small mammal)


## Species body mass in kilograms — the one measured number the rest of this module derives from.
static func mass_kg(config: Dictionary) -> float:
	return maxf(float(config.get("mass_kg", REFERENCE_MASS_KG)), 1.0e-7)


## Whole live mass in simulation units — structural tissue plus the labile reserve plus anything in the gut.
static func live_mass(config: Dictionary) -> float:
	return TISSUE_PER_KG * mass_kg(config)


## The labile energy reserve, i.e. `max_energy`. Scales with mass (M^1.0) because a reserve is a STORE, while
## the burn scales with the body's SURFACE — and the gap between the two is what makes fasting endurance rise
## with body size. This is the whole reason a mouse cannot skip a meal and a bear can hibernate.
static func reserve(config: Dictionary) -> float:
	return live_mass(config) * RESERVE_FRAC


## Non-labile tissue: bone, muscle, organ. What is left of a body once the reserve is spent, and what a
## carcass still weighs.
static func structural(config: Dictionary) -> float:
	return live_mass(config) * (1.0 - RESERVE_FRAC)


static func hydration_capacity(config: Dictionary) -> float:
	return live_mass(config) * LETHAL_WATER_DEFICIT_FRAC


## Water turnover per second. It leaves across the SAME surface the oxygen crosses — respiratory water loss is
## evaporation off the gas-exchange membrane, and an animal that ventilates harder dries out faster — so it is
## a multiple of the body's aerobic capacity rather than a second scaling law. An insect's waterproofed cuticle
## and a bird's efficient lung both come through the heritable `respiratory_capacity` gene that is already in
## that capacity, so there is no thermal-strategy table here and no `if insect`.
##
## THE ORDERING IS THE PHYSICS AND IT USED TO BE BACKWARDS. A terrestrial animal dies of dehydration in about
## three days and of starvation in about thirty: thirst is roughly twenty times the more urgent pressure, in
## every species. The roster had it inverted — a fox reached zero hydration at 100 s and zero energy at 76 s —
## so animals starved before they ever got thirsty and the water drive barely mattered. `WATER_PER_CAPACITY`
## is set so time-to-dehydrate is exactly HALF time-to-starve at every body mass: hydration capacity is 0.15 of
## live mass and the reserve is 0.20, so 0.15 / (0.20 * 1.5) = 0.5 and the ratio is mass-invariant by
## construction. The 1:2 compression rather than the real 1:20 is a stated time-compression choice of the same
## kind as RESP_K's anchor — a strictly real ratio would kill every animal of thirst within seconds of
## spawning — and what is preserved is what is physically meaningful: thirst comes FIRST, always, everywhere.
const WATER_PER_CAPACITY: float = 1.5
static func thirst_rate(c) -> float:
	return WATER_PER_CAPACITY * LACreatureRespiration.capacity_rate(c)


## Bite rate in mass units per second — how fast a mouth can actually process forage. A mouth is sized to feed
## the body behind it, so intake tracks aerobic capacity and inherits the same surface scaling: a villager
## strips a cell far faster than an ant, from geometry rather than a per-species constant. Without a bite limit
## grazing is bounded only by the pasture and one animal would strip a cell in a frame.
const BITE_OVER_CAPACITY: float = 12.0   # a feeding animal ingests up to this multiple of its aerobic capacity
static func bite_rate(c) -> float:
	return LACreatureRespiration.capacity_rate(c) * BITE_OVER_CAPACITY


## Frames from process start within which a spawn counts as part of the FOUNDING population rather than as a
## body made at runtime. A founding biosphere is an initial condition (so is a full ocean); a body appearing
## on frame 400 is matter created mid-run. The boundary is a heuristic — the ecology does not announce when
## its founding wave is over — and it is reported as such, split out rather than folded into one total.
const FOUNDING_FRAMES: int = 60


## Register a newly-built body with the field's biota ledger, so mass that entered the world by SPAWNING is
## visible instead of surfacing later as an unexplained carbon surplus when the animal dies and rots. A BIRTH
## is deliberately not registered: `LACreatureReproduction` debits the mother the newborn's whole mass, so a
## birth moves mass rather than making it, and counting it here would double it.
static func note_spawn(c, from_genome: bool) -> void:
	if from_genome or c == null or c._material == null:
		return
	if not c._material.has_method("note_biota_spawn"):
		return
	c._material.note_biota_spawn(body_mass(c), int(Engine.get_physics_frames()) <= FOUNDING_FRAMES)


## Express the mass-derived physiology onto a freshly-configured creature. Called from LACreatureSetup after
## species/genome expression, and it OVERWRITES whatever the config said for these fields — that is the point.
## `max_energy`, `food_value`, `thirst_rate` and `max_hydration` are no longer twenty independent tuned
## numbers, they are one measured mass and one surface law.
static func apply(c, config: Dictionary) -> void:
	c.mass_kg = mass_kg(config)
	c.structural_mass = structural(config)
	# A config override on the reserve is still honoured for tests and set-pieces; nothing in the roster sets it.
	c.max_energy = float(config.get("max_energy", reserve(config)))
	c.energy = c.max_energy
	c.max_hydration = hydration_capacity(config)
	c.hydration = c.max_hydration
	# These two read the CREATURE (they need its expressed `respiratory_capacity` gene as well as its mass), so
	# they are set after `mass_kg` is on the body rather than off the config dictionary.
	c.thirst_rate = thirst_rate(c)
	c.bite_rate = bite_rate(c)
	# A body is worth what a body weighs. `food_value` was a tuned per-species number unrelated to anything the
	# animal was made of, which is how one kill could yield more meat than the animal ever held.
	c.food_value = body_mass(c)


## Live body mass right now: structural tissue + the labile reserve + whatever is in the gut awaiting
## digestion + the residue awaiting excretion. This is the number a predator's meal, a carcass and a gestation
## are all measured in, so nothing can gain mass a body did not have.
static func body_mass(c) -> float:
	if c == null:
		return 0.0
	return maxf(0.0, float(c.structural_mass) + maxf(0.0, float(c.energy))
		+ maxf(0.0, float(c.gut)) + maxf(0.0, float(c.gut_waste)))


## Take `want` mass out of a live body and return what it actually had, spending the gut and the labile
## reserve first and then structural tissue (an animal in a hard winter catabolises muscle; that is what
## emaciation IS). Used by predation and by gestation, so a meal or a pregnancy can never draw more than the
## body holds.
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


## Keep `food_value` in step with what the body actually weighs, so a starved animal is worth less to a
## predator than a fat one. One assignment per creature per frame; called from the metabolism tick.
static func tick(c) -> void:
	c.food_value = body_mass(c)
