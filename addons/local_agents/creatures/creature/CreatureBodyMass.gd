class_name LACreatureBodyMass
extends RefCounted

## LACreatureBodyMass — ONE MEASURED BODY MASS PER SPECIES, AND EVERY RATE DERIVED FROM IT.
##
## What this replaces. Every physiological rate in the roster used to be a hand-fitted per-species number, and
## the numbers did not agree with each other or with biology: a red fox and a house mouse both carried
## `"metabolism": 1.7`, which is a 260-fold difference in body mass burning fuel at the identical rate. Twenty
## species carried twenty independently-tuned `metabolism` / `max_energy` / `food_value` triples, so nothing
## about the roster was consistent and nothing could be predicted.
##
## Metabolic rate goes as **M^0.75** — Kleiber's law, measured across five orders of magnitude of body mass
## (Kleiber 1932; confirmed by Savage et al. 2004 across 600+ species). It is a physical fact about animals and
## it is hardcoded here as one. The consequence that matters for this simulation is a RATIO, not a rate: a
## reserve scales with mass (M^1.0) while the burn scales as M^0.75, so time-to-starve goes as **M^0.25**. A
## mouse starves about four times faster than a fox of 260 times its mass. Nothing had to be written to make a
## small animal live on a knife edge; it falls out of the exponent.
##
## ENDOTHERM vs ECTOTHERM. A resting ectotherm of a given mass burns roughly a fifth to a tenth of what an
## endotherm of the same mass burns (Bennett & Ruben 1979), because it is not paying to hold a body temperature
## above ambient. Birds run higher than mammals again. Those three are the `basal_scale` factors below, and
## they are the only taxon-shaped numbers here — everything else is one exponent applied to one mass.
##
## WHICH CONSTANTS ARE FACTS AND WHICH ARE UNITS, stated because this repo has been burned by the difference.
##   * `KLEIBER_EXPONENT`, `TIME_EXPONENT`, `WATER_EXPONENT` are measured properties of animals. Do not tune them.
##   * `TISSUE_PER_KG` and `BASAL_COEFF` are UNIT CONVERSIONS: the simulation's mass/energy unit has no
##     kilogram or joule value of its own, so something has to define one, and these two do. `BASAL_COEFF` is
##     anchored so a 5 kg red fox keeps the time-to-starve it had before this change (~76 s), which pins the
##     world's clock to the balance the rest of the game was built against and lets the exponent supply the
##     physics. Anchoring the unit is legitimate; moving `KLEIBER_EXPONENT` to make a population survive is not.
##   * `RESERVE_FRAC` is a measured property (body fat as a fraction of live mass in a wild mammal, ~10-25%).
##
## SIZE IS NOT MASS IN THIS PROJECT, DELIBERATELY. `size` is the visual/collision scale and the roster
## compresses it hard so a beetle is visible beside a villager on a planet-scale world (ant 0.08 against
## villager 1.0, where the real ratio is nearer 0.003). Deriving mass from `size` would import that rendering
## decision into the physics. `mass_kg` is therefore its own species field, carrying the real animal's measured
## mass, and the two are independent on purpose.
##
## Static + dynamic field access on the passed creature, like the other Creature* helpers.
## (Explicit types only, no ':=' inferred typing.)

# --- MEASURED PROPERTIES OF ANIMALS (facts; not tuning knobs) ---------------------------------------------
const KLEIBER_EXPONENT: float = 0.75   # metabolic rate ∝ M^0.75 (Kleiber 1932)
const TIME_EXPONENT: float = 0.25      # biological times (breath-hold, gut passage) ∝ M^0.25 — 1 - 0.75
const WATER_EXPONENT: float = 0.75     # water turnover tracks metabolic rate, so it takes the same exponent
const RESERVE_FRAC: float = 0.20       # labile reserve (fat + glycogen) as a fraction of live mass, wild mammal
## Resting metabolic rate relative to a mammal of the SAME mass. An ectotherm does not pay to hold a body
## temperature above ambient and runs 5-10x lower (Bennett & Ruben 1979); a passerine bird runs higher again.
const BASAL_SCALE: Dictionary = {
	"endotherm": 1.0,        # placental mammal — the reference
	"endotherm_avian": 1.6,  # bird: higher body temperature (~41 °C) and higher mass-specific BMR
	"ectotherm": 0.15,       # insect, fish, reptile, mollusc
}

# --- UNIT CONVERSIONS (what one simulation mass/energy unit means; see the header) --------------------------
#
# ONE MASS UNIT IS THE FIELD'S MASS UNIT, and that is not a cosmetic choice — it is what makes conservation
# across the body/field boundary mean anything at all. An animal's mass is now debited out of the `biomass`
# channel when it grazes and credited into `detritus` when it dies, so a creature "mass unit" and a field
# "mass unit" have to be the same thing or the ledger is comparing apples to nothing.
#
# THE SCALE IS SET BY THE REAL FAUNA:FLORA RATIO. Global animal biomass is about 2 Gt of carbon against about
# 450 Gt for plants — roughly 0.4%. The founding fauna here comes out near 8% of the planet's standing crop,
# which is twenty times the real ratio and deliberately generous (this planet's primary production is
# nutrient-limited, and erring toward a viable biosphere is the conservative direction).
#
# MEASURED, AND IT IS WHY THIS NUMBER MOVED. At the first anchoring — one unit per 1/130 kg — a single 62 kg
# villager massed 8060 units while the ENTIRE PLANET'S standing crop was 300, and the founding fauna's body
# water came to 38,250 against an `h2o_total` of 7,000: the animals outweighed the hydrosphere five times
# over. Both checks fail the same way and both are fixed by the same factor.
#
# EVERY TIMESCALE IS UNCHANGED BY THIS. Time-to-starve is reserve/burn = (TISSUE_PER_KG·RESERVE_FRAC)/
# BASAL_COEFF · M^0.25, and time-to-dehydrate is the same shape over WATER_COEFF, so as long as all three
# move by the same factor no behaviour changes — only the unit does. They were divided by 10,000 together.
const MASS_UNIT_SCALE: float = 1.0e-4  # the factor the three coefficients below were moved by, kept visible
const TISSUE_PER_KG: float = 130.0 * MASS_UNIT_SCALE      # simulation mass units per kilogram of live tissue
const BASAL_COEFF: float = 0.508 * MASS_UNIT_SCALE        # mass units burned per second by a 1 kg endotherm at rest
const REFERENCE_MASS_KG: float = 0.5   # fallback when a species has no measured mass yet (a small mammal)


## Species body mass in kilograms — the one measured number the rest of this module derives from.
static func mass_kg(config: Dictionary) -> float:
	return maxf(float(config.get("mass_kg", REFERENCE_MASS_KG)), 1.0e-7)


## "endotherm" | "endotherm_avian" | "ectotherm". Config-driven, never `if species == X`: a species declares
## what it IS and the physiology follows. Absent, an animal is assumed to be a mammal-grade endotherm, which is
## the conservative choice because it is the more expensive one.
static func strategy(config: Dictionary) -> String:
	var s: String = String(config.get("thermal_strategy", "endotherm"))
	return s if BASAL_SCALE.has(s) else "endotherm"


## Whole live mass in simulation units — structural tissue plus the labile reserve plus anything in the gut.
static func live_mass(config: Dictionary) -> float:
	return TISSUE_PER_KG * mass_kg(config)


## The labile energy reserve, i.e. `max_energy`. Scales with mass (M^1.0) because a reserve is a STORE, while
## the burn below scales as M^0.75 — and the gap between the two exponents is what makes time-to-starve go as
## M^0.25. This is the whole reason a mouse cannot skip a meal and a bear can hibernate.
static func reserve(config: Dictionary) -> float:
	return live_mass(config) * RESERVE_FRAC


## Non-labile tissue: bone, muscle, organ. What is left of a body once the reserve is spent, and what a
## carcass still weighs.
static func structural(config: Dictionary) -> float:
	return live_mass(config) * (1.0 - RESERVE_FRAC)


## BASAL metabolic rate in mass units per second — Kleiber, scaled by thermal strategy. This is the resting
## cost at a comfortable temperature; exertion multiplies it and the thermal module adds the cost of defending
## a body temperature (endotherm) or scales it by ambient warmth (ectotherm Q10).
static func basal_rate(config: Dictionary) -> float:
	var scale: float = float(BASAL_SCALE.get(strategy(config), 1.0))
	return BASAL_COEFF * pow(mass_kg(config), KLEIBER_EXPONENT) * scale


## Water turnover per second. It tracks METABOLIC RATE — respiratory and excretory water loss are both
## proportional to how fast the animal is running — so it carries the same exponent AND the same thermal-
## strategy scale. That second half matters: an insect's cuticle is waterproofed precisely because its
## surface-to-volume ratio would otherwise desiccate it in minutes, and without the scale a beetle came out
## dehydrating five times faster than it could starve, which is the wrong ordering for any animal.
static func thirst_rate(config: Dictionary) -> float:
	var scale: float = float(BASAL_SCALE.get(strategy(config), 1.0))
	return WATER_COEFF * pow(mass_kg(config), WATER_EXPONENT) * scale
## Unit conversion, chosen so time-to-death-by-thirst is HALF time-to-death-by-starvation, at every body mass.
##
## THE ORDERING IS THE PHYSICS AND IT WAS BACKWARDS. A terrestrial animal dies of dehydration in about three
## days and of starvation in about thirty: thirst is roughly twenty times the more urgent pressure, always,
## in every species. The roster had it inverted — a fox reached zero hydration at 100 s and zero energy at
## 76 s — so animals starved before they ever got thirsty and the water drive barely mattered.
##
## The RATIO is compressed to 1:2 rather than the real 1:20, and that is a stated time-compression choice, of
## the same kind as `BASAL_COEFF`: this simulation already compresses a five-year lifespan into 220 seconds,
## and a strictly real ratio would kill every animal of thirst within a few seconds of spawning. What is
## preserved is what is physically meaningful — thirst comes FIRST, and both timescales carry the same M^0.25
## mass scaling, so a mouse dehydrates faster than a fox exactly as it starves faster.
const WATER_COEFF: float = 0.762 * MASS_UNIT_SCALE
## `max_hydration` is the LETHAL WATER DEFICIT, not total body water. An animal is dead long before its tissue
## is dry: losing about 15% of body mass as water is fatal in a mammal. (Total body water is ~65% of mass, and
## using that as the bar meant an animal had to lose four times a lethal amount before the sim noticed.)
const LETHAL_WATER_DEFICIT_FRAC: float = 0.15
static func hydration_capacity(config: Dictionary) -> float:
	return live_mass(config) * LETHAL_WATER_DEFICIT_FRAC


## Breath-hold in seconds. A biological TIME, so M^0.25: a whale dives for many minutes and a mouse for
## seconds, off the same exponent that governs heart rate and gut passage. An animal with an explicit
## `breath_capacity` in its species data keeps it (a diving specialist is a real adaptation, not a mass effect).
const BREATH_COEFF: float = 8.0        # unit conversion: seconds of breath-hold for a 1 kg animal
static func breath_capacity(config: Dictionary) -> float:
	if config.has("breath_capacity"):
		return float(config["breath_capacity"])
	return BREATH_COEFF * pow(mass_kg(config), TIME_EXPONENT)


## Bite rate in mass units per second — how fast a mouth can actually process forage. Intake tracks metabolic
## demand (an animal's mouth is sized to feed its body), so this is the basal rate times the surplus a feeding
## animal can take on above bare maintenance. Without a bite limit, grazing is bounded only by the pasture and
## one animal would strip a cell in a frame.
const BITE_OVER_BASAL: float = 12.0    # a feeding animal ingests up to this multiple of its resting burn
static func bite_rate(config: Dictionary) -> float:
	return basal_rate(config) * BITE_OVER_BASAL


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


## Express the whole derived physiology onto a freshly-configured creature. Called from LACreatureSetup after
## species/genome expression, and it OVERWRITES whatever the config said for these fields — that is the point.
## `metabolism`, `max_energy`, `food_value`, `thirst_rate`, `max_hydration` and `breath_capacity` are no longer
## twenty independent tuned numbers, they are one measured mass and one exponent.
static func apply(c, config: Dictionary) -> void:
	c.mass_kg = mass_kg(config)
	c.thermal_strategy = strategy(config)
	c.structural_mass = structural(config)
	c.max_energy = reserve(config)
	c.energy = c.max_energy
	# THE TWO METABOLIC-RATE GENES, WIRED. `basal_metabolism` and `active_metabolism` were encoded on the DNA
	# strand and read by NOTHING — a declared gene nothing consumes is a promise the code does not keep. The
	# resting gene scales the Kleiber rate here; the working gene scales the exertion multiplier in
	# LACreatureMetabolism.tick. Both are clamped to the real intraspecific spread (see LADNA's locus table).
	c.basal_metabolism = basal_rate(config) * clampf(float(config.get("basal_metabolism", 1.0)), 0.7, 1.3)
	c.active_metabolism = clampf(float(config.get("active_metabolism", 1.0)), 0.7, 1.3)
	c.metabolism = c.basal_metabolism
	c.max_hydration = hydration_capacity(config)
	c.hydration = c.max_hydration
	c.thirst_rate = thirst_rate(config)
	c.breath_capacity = breath_capacity(config)
	c._breath = c.breath_capacity
	c.bite_rate = bite_rate(config)
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


## Take `want` mass out of a live body and return what it actually had, spending the labile reserve first and
## then structural tissue (an animal in a hard winter catabolises muscle; that is what emaciation IS). Used by
## predation and by gestation, so a meal or a pregnancy can never draw more than the body holds.
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
