class_name LACreatureThought
extends RefCounted

## Thought-inspector presentation for LACreature: turns the creature's LIVE cognition into a stable
## individual name, a natural-language "thought", and a few supporting decision/habit/cue lines. It
## SURFACES the existing brain — the last fast-path pick, the last slow-brain resolution (the local
## FunctionGemma model or the offline teacher), the learned policy, and the learned cue associations —
## and NEVER calls a model itself. Static + dependency-free of the LACreature type.
## (Explicit types only — project rule: no ':=' inferred typing.)

# A small pool of friendly names so a clicked animal reads as an individual ("Pip the fox"), not a
# faceless instance. Stable per-creature (keyed by instance id), presentation-only.
const NAMES: Array = [
	"Pip", "Rowan", "Bramble", "Sage", "Fen", "Ash", "Wren", "Juno", "Clover", "Milo",
	"Nova", "Bracken", "Hazel", "Ember", "Tamsin", "Rook", "Willa", "Otter", "Cody", "Maple",
	"Birch", "Dax", "Ivy", "Reed", "Sorrel", "Finch", "Moss", "Kestrel", "Pike", "Vega",
]


static func display_name(c) -> String:
	var idx: int = int(abs(c.get_instance_id())) % NAMES.size()
	return String(NAMES[idx])


## Header for the panel: "Pip the fox · adult".
static func title(c) -> String:
	var maturity: String = "adult" if c.has_method("is_mature") and c.is_mature() else "juvenile"
	return "%s the %s · %s" % [display_name(c), String(c.species), maturity]


## The star line: what the creature is thinking, in natural language. Returns
##   {text, source, is_llm}
## where `is_llm` is true only when the local model actually chose the live behaviour. When no model
## has weighed in, the text is the rule-based read of the same situation (the caller adds the
## "load a model for reasoning" hint).
static func thought(c) -> Dictionary:
	var cog = c.get_cognition() if c.has_method("get_cognition") else null

	var e: int = _energy_bucket(c)
	var h: int = _hydration_bucket(c)

	# A slow-brain resolution is in flight — name that honestly.
	if cog != null and cog.has_method("is_thinking") and cog.is_thinking():
		return {"text": "%s and %s — thinking it over (asking the local model)…"
			% [_cap(_thirst_word(h)), _hunger_word(e)], "source": "local model", "is_llm": false}

	# The star: the local model (or offline teacher) actually decided the live behaviour.
	if cog != null and cog.has_method("last_ask"):
		var ask: Dictionary = cog.last_ask()
		if not ask.is_empty():
			var ae: int = int(ask.get("e", e))
			var ah: int = int(ask.get("h", h))
			var action: String = String(ask.get("action", ""))
			var by_llm: bool = String(ask.get("source", "")) == "llm"
			var who: String = "the local model" if by_llm else "instinct"
			return {
				"text": "%s and %s, so I decided to %s — %s worked it out."
					% [_cap(_thirst_word(ah)), _hunger_word(ae), _intent(action), who],
				"source": ("local model (FunctionGemma, offline)" if by_llm else "offline teacher"),
				"is_llm": by_llm,
			}

	# Rule-based read of the current situation (no model has been consulted for this animal yet).
	var doing: String = LACreatureInspector.describe_activity(String(c.state))
	return {"text": "%s and %s — %s." % [_cap(_thirst_word(h)), _hunger_word(e), doing],
		"source": "rule-based", "is_llm": false}


## Supporting lines under the thought: current behaviour, how the last pick was reached, what it has
## learned, and the strongest cue it watches. All O(1)/O(small) reads of the live brain.
static func detail_lines(c) -> Array:
	var out: Array = []
	out.append("Doing: %s" % LACreatureInspector.describe_activity(String(c.state)))

	var cog = c.get_cognition() if c.has_method("get_cognition") else null
	if cog == null:
		return out

	if cog.has_method("last_choice"):
		var ch: Dictionary = cog.last_choice()
		if not ch.is_empty():
			out.append("Just chose: %s (%s)" % [_intent(String(ch.get("action", ""))), _how_word(String(ch.get("how", "")))])

	var habits: int = cog.policy_size() if cog.has_method("policy_size") else 0
	var asked: int = int(cog.escalations) if "escalations" in cog else 0
	var social: int = int(cog.lessons) if "lessons" in cog else 0
	out.append("Learned: %d habits · asked the model ×%d · %d picked up from the herd" % [habits, asked, social])

	var cue: String = _top_cue(cog)
	if cue != "":
		out.append("Watches for: %s" % cue)
	return out


# --- word banks (buckets → natural language) ----------------------------------------------------

static func _hunger_word(e: int) -> String:
	match e:
		0: return "starving"
		1: return "hungry"
		2: return "well-fed"
		_: return "full"


static func _thirst_word(h: int) -> String:
	match h:
		0: return "parched"
		1: return "thirsty"
		_: return "watered"


static func _intent(action: String) -> String:
	match action:
		"drink": return "get a drink"
		"seek_water": return "go and find water"
		"graze": return "graze here"
		"hunt": return "hunt"
		"rest": return "rest and recover"
		"wander": return "wander with my kind"
		"": return "wait a beat"
		_: return action


static func _how_word(how: String) -> String:
	match how:
		"reflex": return "pure reflex"
		"habit": return "a learned habit"
		"instinct": return "instinct"
		_: return how


# The single strongest cue association this animal has learned to watch (e.g. circling scavengers →
# food), phrased plainly. Returns "" if it has learned no confident cue yet.
static func _top_cue(cog) -> String:
	if not ("cue_values" in cog):
		return ""
	var best_key: String = ""
	var best_val: float = 0.0
	for k in cog.cue_values.keys():
		var v: float = float(cog.cue_values[k])
		if v > best_val:
			best_val = v
			best_key = String(k)
	if best_key == "" or best_val < 1.0:
		return ""
	return "%s (worth %.1f)" % [best_key.replace(":", " that are "), best_val]


static func _energy_bucket(c) -> int:
	var frac: float = 0.0
	if float(c.max_energy) > 0.0:
		frac = clampf(float(c.energy) / float(c.max_energy), 0.0, 1.0)
	return LASituationSignature.energy_bucket(frac)


static func _hydration_bucket(c) -> int:
	var frac: float = 0.0
	if float(c.max_hydration) > 0.0:
		frac = clampf(float(c.hydration) / float(c.max_hydration), 0.0, 1.0)
	return LASituationSignature.hydration_bucket(frac)


static func _cap(s: String) -> String:
	if s == "":
		return s
	return s.substr(0, 1).to_upper() + s.substr(1)
