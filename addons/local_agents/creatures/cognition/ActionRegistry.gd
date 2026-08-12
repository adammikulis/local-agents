class_name LAActionRegistry
extends RefCounted


const ACTIONS: Array = [
	"flee", "hunt", "throw_rock", "scavenge", "graze",
	"drink", "seek_water", "flock", "wander", "rest", "migrate", "investigate",
	# Player COMPANION commands (appended; a bonded/tamed creature obeys these, pre-empting its autonomy —
	# see LACreatureBond + LACompanionController). Harmless for wild creatures: with no bond target they no-op.
	"come", "stay", "follow",
]

# Actions that are *safety reflexes*: when the innate cascade picks one of these, cognition
# never overrides it with a learned/LLM choice and never escalates — survival is not up for
# deliberation. These are the genetically baked reactions (real animals don't "learn" to flee).
const REFLEX_ACTIONS: Array = ["flee"]

# One-line natural-language intent per action. This text is what FunctionGemma reasons over and
# what a finetune specialises on, so keep it concrete and behavioural.
const DESCRIPTIONS: Dictionary = {
	"flee": "Run directly away from the nearest larger predator. Choose when a hunter is close.",
	"hunt": "Chase and bite the nearest prey animal you can eat.",
	"throw_rock": "Hurl a carried rock at prey that is too fast to catch on foot.",
	"scavenge": "Walk to and feed from a nearby carcass (carrion).",
	"graze": "Eat a nearby edible plant.",
	"drink": "Drink from the water you are standing in to restore hydration.",
	"seek_water": "Head toward the nearest water when thirsty.",
	"flock": "Move together with nearby same-species animals (herd/flock).",
	"wander": "Roam to explore when nothing else is pressing.",
	"rest": "Stay nearly still to conserve energy when safe but tired.",
	"migrate": "Travel steadily in one direction to reach new territory or resources.",
	"investigate": "Move toward a food cue — circling scavengers, a carrion scent, or a carrion call.",
	"come": "Go to the player who tamed you (a companion command).",
	"stay": "Hold your ground where you are (a companion command).",
	"follow": "Trail the player who tamed you, keeping close (a companion command).",
}


static func is_valid(name: String) -> bool:
	return ACTIONS.has(name)


static func is_reflex(name: String) -> bool:
	return REFLEX_ACTIONS.has(name)


static func index_of(name: String) -> int:
	return ACTIONS.find(name)


static func tool_specs() -> Array:
	var specs: Array = []
	for name in ACTIONS:
		var params: Dictionary = _parameters_for(String(name))
		specs.append({
			"type": "function",
			"function": {
				"name": String(name),
				"description": String(DESCRIPTIONS.get(name, "")),
				"parameters": params,
			},
		})
	return specs


## Per-action JSON-Schema parameters. Most creature actions are nullary; `migrate` carries a
## compass direction so the model can express intent an emergent heuristic can act on.
static func _parameters_for(name: String) -> Dictionary:
	if name == "migrate":
		return {
			"type": "object",
			"properties": {
				"direction": {
					"type": "string",
					"enum": ["north", "south", "east", "west"],
					"description": "Compass heading to travel toward.",
				},
			},
			"required": ["direction"],
		}
	return {"type": "object", "properties": {}}


## Map a compass name to a flat unit heading (used by both the LLM `migrate` arg and heuristics).
static func direction_vector(direction: String) -> Vector3:
	match direction:
		"north":
			return Vector3(0.0, 0.0, -1.0)
		"south":
			return Vector3(0.0, 0.0, 1.0)
		"east":
			return Vector3(1.0, 0.0, 0.0)
		"west":
			return Vector3(-1.0, 0.0, 0.0)
	return Vector3.ZERO
