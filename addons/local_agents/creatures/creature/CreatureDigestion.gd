class_name LACreatureDigestion
extends RefCounted

## Gut buffer + digestion for LocalAgentCreature. Turns ingested food into energy and waste over time, replacing
## the old instant-feed path. Eating no longer credits energy at the moment of the bite; a bite adds biomass
## to a per-creature gut buffer, and tick() digests that buffer down each frame, converting biomass into
## energy at a digestive efficiency (scaled by the creature's microbiome, so a herbivore's gut flora ferments
## fibrous plant matter it otherwise couldn't extract) while the indigestible remainder becomes feces the
## creature later excretes. So a starving animal with a full gut recovers over seconds, not instantly; a
## well-fed one buffers the surplus in its gut; and an empty gut means no energy until it eats again.
##
## Matter is (roughly) conserved: digested biomass -> energy + waste. Digestion is PER-CREATURE state, never a
## field CA. Only the waste OUTPUT enters the shared field, and it does so via LACreatureExcretion on that
## module's existing feces cadence (this module only raises c.gut_waste; it never deposits, so there is no
## double-counting). Everything here is O(1) per creature per frame.
##
## State lives on the creature as plain fields (gut, gut_capacity, gut_waste, microbiome) so this module owns
## digestion without editing the brain. Static + dependency-free of the LocalAgentCreature type (dynamic field access,
## like the other Creature* helpers). (Explicit types only, no ':=' inferred typing.)

# Gut sizing + rates. The gut holds up to CAPACITY_FRAC of the creature's max energy as buffered biomass (a big
# meal is stored and drawn down over time). DIGEST_RATE is the fraction of the CURRENT gut contents converted
# each second, so digestion is exponential — fast right after a meal, tapering as the gut empties — which is
# why a starving animal recovers over a handful of seconds rather than in a single frame.
const CAPACITY_FRAC: float = 0.85       # gut capacity as a fraction of max_energy (biomass units == energy units)
const DIGEST_RATE: float = 0.22         # fraction of current gut biomass digested per second

# Digestive efficiency: the fraction of digested biomass that becomes ENERGY; the remainder (1 - efficiency)
# becomes feces. A creature's realised efficiency is BASE_EFFICIENCY * microbiome, clamped to 1. The microbiome
# is the gut-flora scalar (set at spawn from diet): a herbivore's flora ferments cellulose it otherwise could
# not digest, so it extracts more energy from plant matter (and, being the base of the food web, stays near the
# old throughput); carnivores digest meat without help at the base rate. Not hardcoded per species — one scalar.
const BASE_EFFICIENCY: float = 0.82
const MICROBIOME_HERBIVORE: float = 1.12   # gut-flora bonus for a plant-fermenting herbivore (-> ~0.92 efficiency)
const MICROBIOME_DEFAULT: float = 1.0      # carnivore / omnivore / scavenger: no cellulose flora, base rate

## SATIETY MARGIN, as a FRACTION of the reserve. At/above (1 - this) of max_energy the gut holds instead of
## digesting, buffering the surplus. It is a fraction and never an absolute: an absolute margin exceeds the
## whole reserve of a small animal, which stops its digestion entirely and does so silently.
const FULL_FRAC: float = 0.999          # at/above this fraction of max_energy the gut holds (satiety)


## Size the gut and pick the microbiome from diet, once at spawn (called from LocalAgentCreature.setup after max_energy
## and diet are known). A herbivore is born with cellulose-fermenting flora; every other diet digests at base.
static func setup(c) -> void:
	if c == null:
		return
	c.gut = 0.0
	c.gut_waste = 0.0
	c.gut_digestibility = 1.0
	# Gut volume is ISOMETRIC with body mass (M^1.0) — an animal's gut is a fixed fraction of it — so sizing it
	# off `max_energy`, which is itself the mass-proportional reserve, keeps the scaling right for free. No
	# absolute floor: one would exceed a small animal's whole body.
	c.gut_capacity = maxf(float(c.max_energy) * CAPACITY_FRAC, 0.0)
	c.microbiome = MICROBIOME_HERBIVORE if String(c.diet) == "herbivore" else MICROBIOME_DEFAULT


# GRAZING. A plant-eater standing on vegetated ground nibbles the grass living there — the field's real
# `biomass` channel, the one photosynthesis (R19) actually grows — and the pasture is DEBITED by exactly what
# the mouth takes. Where nothing is growing, an animal gets nothing, which is what makes starvation reachable.
# The crop is at the mouth: photosynthesis (R19) is gated `GATE_NEAR_GROUND`, the open cell with rock beneath
# it (see LABioRecords), which is where a grazing animal stands.
#
# THE BITE IS BOUNDED BY THE ANIMAL, NOT BY A GLOBAL RATE. `LACreatureBodyMass.bite_rate` scales intake with
# the animal's own metabolic demand, so a villager strips a cell far faster than an ant, from one exponent
# rather than a per-species constant. What the pasture could not supply comes back as `biota_graze_short`.
#
# FILTER FEEDERS AND GRAZERS ARE THE SAME RULE. A whale straining plankton out of the water column and a
# rabbit cropping grass are both taking the field's standing crop at their own cell; there is no separate
# filter-feeding code, and `DIETS_THAT_GRAZE` is config, not an identity branch.
const DIETS_THAT_GRAZE: PackedStringArray = ["herbivore", "grazer", "filter_feeder"]
## Water carried by each unit of forage. Fresh plant matter is roughly 75% water by mass against ~25% dry
## matter, so a unit of the carbon the `biomass` channel tracks comes with about three units of water.
const FORAGE_WATER_PER_MASS: float = 3.0
## Water carried by each unit of FLESH. Vertebrate soft tissue runs near 70% water, so meat is slightly drier
## than fresh forage per unit of carbon — which is why obligate carnivores still drink and grazers often do not.
const FLESH_WATER_PER_MASS: float = 2.3

static func ambient_graze(c, pos: Vector3, delta: float) -> void:
	if c == null or delta <= 0.0 or c._material == null:
		return
	if not DIETS_THAT_GRAZE.has(String(c.diet)):
		return
	if c.gut >= c.gut_capacity:
		return                                       # gut full — no room to nibble more
	if not c._material.has_method("graze_biomass"):
		return
	var want: float = float(c.bite_rate) * delta * LAAblate.evo_fast()
	if want <= 0.0:
		return
	var got: float = c._material.graze_biomass(pos, want)
	if got <= 0.0:
		return
	ingest(c, got, {"type": LAFood.TYPE_CARBS, "state": LAFood.STATE_LIVING, "value": got})
	# FORAGE WATER. Most terrestrial animals get most of their water from what they eat, and small ones —
	# insects, desert rodents — very often never drink free water at all. That is not a convenience: fresh
	# forage is roughly three-quarters water by mass, and the plant lifted that water out of the ground, so a
	# grazer eating it is drinking the groundwater at one remove. Drawn through the SAME debit as a drink, out
	# of the field at the animal's own cell, so it conserves rather than appearing from the plant's carbon.
	# (Metabolic water is deliberately NOT credited: the substrate's `biomass` is a carbon proxy with no
	# hydrogen in it, so oxidising it cannot honestly yield H₂O.)
	if c._material.has_method("drink_water") and c.hydration < c.max_hydration:
		var thirsty_for: float = minf(got * FORAGE_WATER_PER_MASS, float(c.max_hydration) - float(c.hydration))
		if thirsty_for > 0.0:
			c.hydration += c._material.drink_water(pos, thirsty_for)


## A bite: add its biomass to the gut buffer, bounded by capacity (a stuffed gut can't hold more — the excess
## is simply not taken). `biomass` is the food's energy-equivalent value (the same number the old path credited
## straight to energy); `profile` is accepted for future diet-fit nuance but unused today. O(1).
static func ingest(c, biomass: float, _profile: Dictionary = {}) -> void:
	if c == null or biomass <= 0.0:
		return
	var taken: float = minf(biomass, maxf(0.0, float(c.gut_capacity) - float(c.gut)))
	if taken <= 0.0:
		return
	# Mass-weighted DIGESTIBILITY of what is in the gut. A gut holds a mixture, so a bite of rotten carrion
	# blends with the fresh grass already in there rather than replacing its yield. This is where the food's
	# state now acts — on how much energy comes out per unit mass, never on how much mass went in.
	var d: float = LAFood.digestibility(_profile)
	var held: float = maxf(0.0, float(c.gut))
	c.gut_digestibility = ((c.gut_digestibility * held) + (d * taken)) / maxf(held + taken, 0.0001)
	c.gut = held + taken
	# Let the gut flora learn from this bite (shifts recent_diet toward the food's plant-fraction) — one source of
	# truth: the same event that buffers the food adapts the microbiome. Guarded (null before setup / on old actors).
	if "gut_microbiome" in c and c.gut_microbiome != null:
		c.gut_microbiome.note_food(_profile, biomass)


## Digest a slice of the gut this frame: convert it to energy at the realised efficiency and bank the
## indigestible remainder as pending feces (c.gut_waste), which LACreatureExcretion deposits on its cadence.
## An empty gut yields nothing — the creature must eat. A creature already at full energy HOLDS its gut
## (satiety), so the surplus is buffered and matter is conserved until energy is burned back down. O(1).
static func tick(c, delta: float) -> void:
	if c == null or c.gut <= 0.0 or delta <= 0.0:
		return
	if c.energy >= c.max_energy * FULL_FRAC:
		return                                       # sated: hold the gut, buffer the surplus (no matter lost)
	# LA_EVO_FAST compresses digestion throughput by the SAME factor as the metabolic burn (CreatureMetabolism),
	# so energy recovery keeps pace with the faster burn — a bite refills proportionally faster and the population
	# doesn't starve at high fast-factors. The minf cap keeps it bounded/conserved (never digest more than held).
	var digested: float = minf(c.gut, c.gut * DIGEST_RATE * delta * LAAblate.evo_fast())
	if digested <= 0.0:
		return
	c.gut -= digested
	# Realised efficiency uses the DYNAMIC gut-flora yield (adapts to lived diet) when present, else the static
	# spawn-time microbiome scalar. Bounded/floored inside multiplier() so it stays near the old 1.12 range — no
	# food-web destabilisation.
	var mb: float = c.gut_microbiome.multiplier() if ("gut_microbiome" in c and c.gut_microbiome != null) else float(c.microbiome)
	var efficiency: float = clampf(BASE_EFFICIENCY * mb * float(c.gut_digestibility), 0.0, 1.0)
	var to_energy: float = digested * efficiency
	# A full reserve does NOT destroy the surplus. `minf(max_energy, …)` silently deleted whatever did not fit,
	# which is small (the early-out above stops digestion near satiety) but is still matter vanishing. The
	# overflow goes back to the gut, where the next frame will digest it once the reserve has room.
	var room: float = maxf(0.0, float(c.max_energy) - float(c.energy))
	var absorbed: float = minf(to_energy, room)
	c.energy += absorbed
	c.gut += to_energy - absorbed
	c.gut_waste += digested - to_energy              # matter conserved: digested == energy gained + waste


## Gut fullness 0..1 — how much of its capacity is buffered right now. Read by the hunger signal and the
## eating gate so a creature that has just eaten (full gut, still digesting) does not keep foraging.
static func gut_fill(c) -> float:
	if c == null or c.gut_capacity <= 0.0:
		return 0.0
	return clampf(c.gut / c.gut_capacity, 0.0, 1.0)


## The single hunger signal (0 = sated, 1 = starving), blending energy deficit AND an empty gut: a creature
## with a full gut is not hungry even at lower energy (food is on the way), and a creature near full energy is
## not hungry regardless. This is the one value the forage drive and the affinity smell-steering both read, so
## they agree on when the animal is hungry. O(1).
static func hunger(c) -> float:
	if c == null or c.max_energy <= 0.0:
		return 0.0
	var deficit: float = clampf(1.0 - float(c.energy) / float(c.max_energy), 0.0, 1.0)
	return clampf(deficit * (1.0 - gut_fill(c)), 0.0, 1.0)


## Boolean hunger off the near-vestigial hungry_at threshold, now given real meaning: hungry once the hunger
## signal crosses (1 - hungry_at) — i.e. energy has fallen far enough AND the gut is not buffering a meal.
static func is_hungry(c) -> bool:
	if c == null:
		return false
	return hunger(c) >= (1.0 - float(c.hungry_at))
