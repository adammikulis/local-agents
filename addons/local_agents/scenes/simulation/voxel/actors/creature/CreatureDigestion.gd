class_name LACreatureDigestion
extends RefCounted

## Gut buffer + digestion for LACreature — turns ingested food into energy and waste over time, replacing
## the old instant-feed path. Eating no longer credits energy at the moment of the bite; a bite adds biomass
## to a per-creature gut buffer, and tick() digests that buffer down each frame, converting biomass into
## energy at a digestive efficiency (scaled by the creature's microbiome — a herbivore's gut flora ferments
## fibrous plant matter it otherwise couldn't extract) while the indigestible remainder becomes feces the
## creature later excretes. So a starving animal with a full gut recovers over seconds, not instantly; a
## well-fed one buffers the surplus in its gut; and an empty gut means no energy until it eats again.
##
## Matter is (roughly) conserved: digested biomass -> energy + waste. Digestion is PER-CREATURE state, never a
## field CA — only the waste OUTPUT enters the shared field, and it does so via LACreatureExcretion on that
## module's existing feces cadence (this module only raises c.gut_waste; it never deposits, so there is no
## double-counting). Everything here is O(1) per creature per frame.
##
## State lives on the creature as plain fields (gut, gut_capacity, gut_waste, microbiome) so this module owns
## digestion without editing the brain. Static + dependency-free of the LACreature type (dynamic field access,
## like the other Creature* helpers). (Explicit types only — project rule: no ':=' inferred typing.)

# Gut sizing + rates. The gut holds up to CAPACITY_FRAC of the creature's max energy as buffered biomass (a big
# meal is stored and drawn down over time). DIGEST_RATE is the fraction of the CURRENT gut contents converted
# each second, so digestion is exponential — fast right after a meal, tapering as the gut empties — which is
# why a starving animal recovers over a handful of seconds rather than in a single frame. Tune these two knobs
# (and the efficiencies below) to match net intake to the old instant feed if the population drifts.
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

const FULL_EPS: float = 0.01            # at/above (max_energy - this) the gut holds (satiety) — buffers surplus


## Size the gut and pick the microbiome from diet, once at spawn (called from LACreature.setup after max_energy
## and diet are known). A herbivore is born with cellulose-fermenting flora; every other diet digests at base.
static func setup(c) -> void:
	if c == null:
		return
	c.gut = 0.0
	c.gut_waste = 0.0
	c.gut_capacity = maxf(float(c.max_energy) * CAPACITY_FRAC, 1.0)
	c.microbiome = MICROBIOME_HERBIVORE if String(c.diet) == "herbivore" else MICROBIOME_DEFAULT


## A bite: add its biomass to the gut buffer, bounded by capacity (a stuffed gut can't hold more — the excess
## is simply not taken). `biomass` is the food's energy-equivalent value (the same number the old path credited
## straight to energy); `profile` is accepted for future diet-fit nuance but unused today. O(1).
static func ingest(c, biomass: float, _profile: Dictionary = {}) -> void:
	if c == null or biomass <= 0.0:
		return
	c.gut = minf(c.gut_capacity, c.gut + biomass)


## Digest a slice of the gut this frame: convert it to energy at the realised efficiency and bank the
## indigestible remainder as pending feces (c.gut_waste), which LACreatureExcretion deposits on its cadence.
## An empty gut yields nothing — the creature must eat. A creature already at full energy HOLDS its gut
## (satiety), so the surplus is buffered and matter is conserved until energy is burned back down. O(1).
static func tick(c, delta: float) -> void:
	if c == null or c.gut <= 0.0 or delta <= 0.0:
		return
	if c.energy >= c.max_energy - FULL_EPS:
		return                                       # sated: hold the gut, buffer the surplus (no matter lost)
	# LA_EVO_FAST compresses digestion throughput by the SAME factor as the metabolic burn (CreatureMetabolism),
	# so energy recovery keeps pace with the faster burn — a bite refills proportionally faster and the population
	# doesn't starve at high fast-factors. The minf cap keeps it bounded/conserved (never digest more than held).
	var digested: float = minf(c.gut, c.gut * DIGEST_RATE * delta * LAAblate.evo_fast())
	if digested <= 0.0:
		return
	c.gut -= digested
	var efficiency: float = clampf(BASE_EFFICIENCY * float(c.microbiome), 0.0, 1.0)
	var to_energy: float = digested * efficiency
	c.energy = minf(c.max_energy, c.energy + to_energy)
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
