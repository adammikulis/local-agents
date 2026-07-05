class_name LAFood
extends RefCounted

## Unified food model: EVERYTHING edible is just "food", described by a nutrition TYPE and a life
## STATE. An animal eats what its diet accepts; how much energy it gains is the food's base value
## scaled by state (a fresh kill beats a rotten one; cooked beats raw). All data-driven off a tiny
## `food_profile()` any edible actor returns — no per-food-source branching in the creatures.
##
## A food's profile is a Dictionary: { "type": <carbs|meat|fat>, "state": <living|dead|decayed|cooked>,
## "value": <base energy float> }.
##
## (Explicit types only — project rule: no ':=' inferred typing.)

const TYPE_CARBS: String = "carbs"      # plants, fruit, grain
const TYPE_MEAT: String = "meat"        # flesh
const TYPE_FAT: String = "fat"          # rich tissue

const STATE_LIVING: String = "living"   # still alive — meat must be hunted; carbs can be grazed
const STATE_DEAD: String = "dead"       # a fresh carcass
const STATE_DECAYED: String = "decayed" # rotting — worth less, tolerated mainly by scavengers
const STATE_COOKED: String = "cooked"   # prepared — worth more (a hook for villager cooking)

# Energy multiplier by state: rot halves the value; cooking boosts it.
const STATE_VALUE: Dictionary = {
	"living": 1.0,
	"dead": 1.0,
	"decayed": 0.5,
	"cooked": 1.6,
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


## Base value scaled by state — the actual energy a full portion of this food is worth.
static func value(profile: Dictionary) -> float:
	var base: float = float(profile.get("value", 0.0))
	return base * state_mult(profile)


static func state_mult(profile: Dictionary) -> float:
	return float(STATE_VALUE.get(String(profile.get("state", "dead")), 1.0))
