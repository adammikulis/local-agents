class_name LAFood
extends RefCounted

## Unified food model: EVERYTHING edible is just "food", described by a nutrition TYPE and a life
## STATE. An animal eats what its diet accepts; how much energy it gains is the food's base value
## scaled by state (a fresh kill beats a rotten one; cooked beats raw). All data-driven off a tiny
## `food_profile()` any edible actor returns, with no per-food-source branching in the creatures.
##
## A food's profile is a Dictionary: { "type": <carbs|meat|fat>, "state": <living|dead|decayed|cooked>,
## "value": <base energy float> }.
##
## (Explicit types only, no ':=' inferred typing.)

const TYPE_CARBS: String = "carbs"      # plants, fruit, grain
const TYPE_MEAT: String = "meat"        # flesh
const TYPE_FAT: String = "fat"          # rich tissue

const STATE_LIVING: String = "living"   # still alive — meat must be hunted; carbs can be grazed
const STATE_DEAD: String = "dead"       # a fresh carcass
const STATE_DECAYED: String = "decayed" # rotting — worth less, tolerated mainly by scavengers
const STATE_COOKED: String = "cooked"   # prepared — worth more (a hook for villager cooking)

# State changes DIGESTIBILITY, not mass. Cooking gelatinises starch and denatures protein, so more of a
# given mass is assimilated rather than passed (Wrangham); putrefaction leaves behind the fraction microbes
# could not use, so it yields less. Both are multipliers on EFFICIENCY, applied in LACreatureDigestion where
# the gut converts mass to energy; the mass ledger is untouched by either.
const STATE_DIGESTIBILITY: Dictionary = {
	"living": 1.0,
	"dead": 1.0,
	"decayed": 0.65,   # microbes got the easy fraction first
	"cooked": 1.25,    # gelatinised starch / denatured protein: more of the same mass is assimilated
}

# Which nutrition types each diet will eat. Scavengers eat flesh like carnivores but (see below)
# only when it is already dead — they do not make their own kills.
const DIET_TYPES: Dictionary = {
	"herbivore": ["carbs"],
	"carnivore": ["meat", "fat"],
	"scavenger": ["meat", "fat"],
	"omnivore": ["carbs", "meat", "fat"],
}


static func diet_eats_type(diet: String, food_type: String) -> bool:
	var types: Array = DIET_TYPES.get(diet, ["carbs"])
	return types.has(food_type)


## Can `diet` eat this profile by FORAGING (picking it up off the ground / grazing), i.e. without a
## kill? Living meat (prey) is excluded here — that goes through the hunt behaviour; living carbs
## (plants) can be grazed directly. Dead/decayed/cooked food anyone with the right diet can eat.
static func can_forage(diet: String, profile: Dictionary) -> bool:
	var food_type: String = String(profile.get("type", ""))
	if not diet_eats_type(diet, food_type):
		return false
	if String(profile.get("state", "dead")) == STATE_LIVING:
		return food_type == TYPE_CARBS
	return true


## The MASS a full portion of this food is. No state multiplier: what leaves the food is what enters the
## animal, and state is expressed as digestibility below instead.
static func value(profile: Dictionary) -> float:
	return maxf(0.0, float(profile.get("value", 0.0)))


## How much ENERGY a gut extracts per unit mass of this food, relative to fresh. Applied in
## LACreatureDigestion, never to the mass ingested — see the STATE_DIGESTIBILITY note above.
static func digestibility(profile: Dictionary) -> float:
	return float(STATE_DIGESTIBILITY.get(String(profile.get("state", "dead")), 1.0))
