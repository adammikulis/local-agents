class_name LACreatureDigestion
extends RefCounted



const CAPACITY_FRAC: float = 0.85       # gut capacity as a fraction of max_energy (biomass units == energy units)
const DIGEST_RATE: float = 0.22         # fraction of current gut biomass digested per second

const BASE_EFFICIENCY: float = 0.82
const MICROBIOME_HERBIVORE: float = 1.12   # gut-flora bonus for a plant-fermenting herbivore (-> ~0.92 efficiency)
const MICROBIOME_DEFAULT: float = 1.0      # carnivore / omnivore / scavenger: no cellulose flora, base rate

const FULL_FRAC: float = 0.999          # at/above this fraction of max_energy the gut holds (satiety)


## Size the gut and pick the microbiome from diet.
static func setup(c) -> void:
	if c == null:
		return
	c.gut = 0.0
	c.gut_waste = 0.0
	c.gut_digestibility = 1.0
	# Gut volume is isometric with body mass, so it sizes off `max_energy` (the mass-proportional reserve).
	c.gut_capacity = maxf(float(c.max_energy) * CAPACITY_FRAC, 0.0)
	c.microbiome = MICROBIOME_HERBIVORE if String(c.diet) == "herbivore" else MICROBIOME_DEFAULT


const DIETS_THAT_GRAZE: PackedStringArray = ["herbivore", "grazer", "filter_feeder"]
const FORAGE_WATER_PER_MASS: float = 3.0   # fresh plant matter is ~0.75 water by mass
const FLESH_WATER_PER_MASS: float = 2.3    # vertebrate soft tissue is ~0.70 water by mass

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
	if c._material.has_method("drink_water") and c.hydration < c.max_hydration:
		var thirsty_for: float = minf(got * FORAGE_WATER_PER_MASS, float(c.max_hydration) - float(c.hydration))
		if thirsty_for > 0.0:
			c.hydration += c._material.drink_water(pos, thirsty_for)


## A bite: add its biomass to the gut, bounded by capacity. Excess is not taken.
static func ingest(c, biomass: float, _profile: Dictionary = {}) -> void:
	if c == null or biomass <= 0.0:
		return
	var taken: float = minf(biomass, maxf(0.0, float(c.gut_capacity) - float(c.gut)))
	if taken <= 0.0:
		return
	# Mass-weighted DIGESTIBILITY of what is in the gut.
	var d: float = LAFood.digestibility(_profile)
	var held: float = maxf(0.0, float(c.gut))
	c.gut_digestibility = ((c.gut_digestibility * held) + (d * taken)) / maxf(held + taken, 0.0001)
	c.gut = held + taken
	# Let the gut flora learn from this bite (shifts recent_diet toward the food's plant-fraction).
	if "gut_microbiome" in c and c.gut_microbiome != null:
		c.gut_microbiome.note_food(_profile, biomass)


static func tick(c, delta: float) -> void:
	if c == null or c.gut <= 0.0 or delta <= 0.0:
		return
	# A sated animal with tissue still to build keeps digesting, into STRUCTURE rather than reserve.
	var growing: bool = LACreatureBodyMass.growth_deficit(c) > 0.0
	if c.energy >= c.max_energy * FULL_FRAC and not growing:
		return                                       # sated and grown: hold the gut, buffer it (no matter lost)
	# LA_EVO_FAST compresses digestion throughput by the SAME factor as the metabolic burn (CreatureMetabolism).
	var digested: float = minf(c.gut, c.gut * DIGEST_RATE * delta * LAAblate.evo_fast())
	if digested <= 0.0:
		return
	c.gut -= digested
	var mb: float = c.gut_microbiome.multiplier() if ("gut_microbiome" in c and c.gut_microbiome != null) else float(c.microbiome)
	var efficiency: float = clampf(BASE_EFFICIENCY * mb * float(c.gut_digestibility), 0.0, 1.0)
	var to_energy: float = digested * efficiency
	# A full reserve does not destroy the surplus: the overflow returns to the gut.
	var room: float = maxf(0.0, float(c.max_energy) - float(c.energy))
	var absorbed: float = minf(to_energy, room)
	c.energy += absorbed
	# What the reserve had no room for builds tissue, up to what this body still owes its age.
	var built: float = LACreatureBodyMass.grow(c, to_energy - absorbed)
	c.gut += to_energy - absorbed - built
	c.gut_waste += digested - to_energy              # matter conserved: digested == energy gained + waste


## Gut fullness 0..1 — how much of its capacity is buffered right now.
static func gut_fill(c) -> float:
	if c == null or c.gut_capacity <= 0.0:
		return 0.0
	return clampf(c.gut / c.gut_capacity, 0.0, 1.0)


static func hunger(c) -> float:
	if c == null or c.max_energy <= 0.0:
		return 0.0
	var deficit: float = clampf(1.0 - float(c.energy) / float(c.max_energy), 0.0, 1.0)
	return clampf(deficit * (1.0 - gut_fill(c)), 0.0, 1.0)


## Boolean hunger off the near-vestigial hungry_at threshold, now given real meaning.
static func is_hungry(c) -> bool:
	if c == null:
		return false
	return hunger(c) >= (1.0 - float(c.hungry_at))
