class_name LAFood
extends RefCounted


const TYPE_CARBS: String = "carbs"      # plants, fruit, grain
const TYPE_MEAT: String = "meat"        # flesh
const TYPE_FAT: String = "fat"          # rich tissue

const STATE_LIVING: String = "living"   # still alive — meat must be hunted; carbs can be grazed
const STATE_DEAD: String = "dead"       # a fresh carcass
const STATE_DECAYED: String = "decayed" # rotting — worth less, tolerated mainly by scavengers
const STATE_COOKED: String = "cooked"   # prepared — worth more (a hook for villager cooking)

const STATE_DIGESTIBILITY: Dictionary = {
	"living": 1.0,
	"dead": 1.0,
	"decayed": 0.65,   # microbes got the easy fraction first
	"cooked": 1.25,    # gelatinised starch / denatured protein: more of the same mass is assimilated
}

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


static func value(profile: Dictionary) -> float:
	return maxf(0.0, float(profile.get("value", 0.0)))


## How much ENERGY a gut extracts per unit mass of this food, relative to fresh. Applied in
## LACreatureDigestion, never to the mass ingested — see the STATE_DIGESTIBILITY note above.
static func digestibility(profile: Dictionary) -> float:
	return float(STATE_DIGESTIBILITY.get(String(profile.get("state", "dead")), 1.0))
