class_name LAActionRegistry
extends RefCounted

## The single source of truth for the discrete "function calls" a creature can perform.
##
## This one registry is consumed three ways:
##   1. Fast tier (System 1) — the set of action names its heuristic policy chooses among.
##   2. Slow tier (System 2) — the `tools` list declared to FunctionGemma, and the label space
##      its returned function call must fall within.
##   3. Auto-finetune — the tool schemas emitted into every training example, so the dataset's
##      labels are exactly "the function calls we have in our program."
##
## The registry owns only the *schemas / names* (data). The *executors* that turn a chosen
## action into a heading/effect live on LACreature (`_execute_action`) because they need creature
## internals. Keeping the two apart lets the fast policy, the LLM, and the dataset all agree on a
## vocabulary without any of them depending on movement code.
##
## (Explicit types only — project rule: no ':=' inferred typing.)

# Canonical action vocabulary. Order is stable so a policy/genome can index by it.
# (A plain Array literal — a PackedStringArray(...) constructor is not a constant expression.)
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


## OpenAI-style tool specs handed to the llama-server (`--jinja`) path as the `tools` option.
## The FunctionGemma chat template renders these into its `<start_function_declaration>` blocks
## and parses the model's `<start_function_call>` back into a `tool_calls` array for us.
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
