class_name LAFunctionGemmaClient
extends RefCounted

## Stateless helpers that translate a creature's situation into a FunctionGemma (llama.cpp
## llama-server, launched with `--jinja`) chat-completions request and translate the reply back into
## one of our discrete action names. Nothing here holds state or touches the scene — it is pure data
## shaping, so it is trivial to unit-test and equally usable by the auto-finetune exporter.
##
## The server parses the model's `<start_function_call>` into an OpenAI-style
## `choices[].message.tool_calls[]`, so the happy path is simply reading the first tool call's name.
## We keep a content-scanning fallback for servers/templates that emit the call inline as text.
##
## (Explicit types only — project rule: no ':=' inferred typing.)

# Coarse human labels for the discrete signature buckets (see LASituationSignature).
const ENERGY_WORDS: Array = ["starving", "low", "adequate", "full"]
const HYDRATION_WORDS: Array = ["parched", "thirsty", "hydrated"]


## The system/developer instruction. It frames the model as an animal that must commit to exactly one
## of the offered survival functions — no prose, no multi-call.
static func developer_prompt() -> String:
	return (
		"You are a wild animal choosing your very next action in order to stay alive. "
		+ "You are told your own body state and everything you can currently see. "
		+ "You MUST call exactly one of the provided functions — the single one that best keeps you "
		+ "alive right now. Never call more than one function and never reply in prose."
	)


## Concise natural-language description of the animal's situation (kept under ~80 words) so
## FunctionGemma can pick a function. Draws on the cheap signature buckets plus the rich escalation
## context (what is visible, day/night, at water).
static func context_prompt(sig: Dictionary, context: Dictionary) -> String:
	var species: String = String(context.get("species", "animal"))
	var diet: String = String(context.get("diet", "herbivore"))
	var e: int = int(sig.get("e", 3))
	var h: int = int(sig.get("h", 2))
	var energy_word: String = ENERGY_WORDS[clampi(e, 0, ENERGY_WORDS.size() - 1)]
	var hydration_word: String = HYDRATION_WORDS[clampi(h, 0, HYDRATION_WORDS.size() - 1)]
	var e_pct: int = int(round(float(context.get("energy_frac", 0.0)) * 100.0))
	var h_pct: int = int(round(float(context.get("hydration_frac", 0.0)) * 100.0))
	var time_word: String = "night" if bool(context.get("night", false)) else "day"
	var ground: String = "standing in water" if bool(context.get("at_water", false)) else "on dry ground"

	var seen: PackedStringArray = PackedStringArray()
	if bool(context.get("predator_visible", false)):
		seen.append("a larger predator")
	if bool(context.get("prey_visible", false)):
		seen.append("prey you can eat")
	if bool(context.get("plant_visible", false)):
		seen.append("an edible plant")
	if bool(context.get("carrion_visible", false)):
		seen.append("a carcass")
	var visible: String = "nothing notable"
	if seen.size() > 0:
		visible = ", ".join(seen)

	return (
		"You are a %s (%s). Energy is %s (%d%%), hydration is %s (%d%%). It is %s and you are %s. "
		+ "You can see: %s. Choose the one function that best keeps you alive."
	) % [species, diet, energy_word, e_pct, hydration_word, h_pct, time_word, ground, visible]


## Build the OpenAI chat-completions body for the llama-server `/v1/chat/completions` endpoint.
## `tool_specs` is expected to be LAActionRegistry.tool_specs(); `tool_choice: "required"` forces a
## call, low temperature keeps the pick decisive, and a tiny token cap keeps latency down.
static func build_request(model_name: String, sig: Dictionary, context: Dictionary, tool_specs: Array) -> Dictionary:
	return {
		"model": model_name,
		"messages": [
			{"role": "system", "content": developer_prompt()},
			{"role": "user", "content": context_prompt(sig, context)},
		],
		"tools": tool_specs,
		"tool_choice": "required",
		"temperature": 0.3,
		"max_tokens": 64,
	}


## Extract the chosen function name from a parsed chat-completions response. Returns "" when the
## response contains no valid, known action. Prefers the structured `tool_calls`; falls back to
## scanning assistant content for a known action name (for non-jinja / inline-call servers).
static func parse_action(response: Dictionary) -> String:
	if response.is_empty():
		return ""
	var choices: Array = _as_array(response.get("choices", []))
	if choices.is_empty():
		return ""
	var first = choices[0]
	if not (first is Dictionary):
		return ""
	var message: Dictionary = _as_dict((first as Dictionary).get("message", {}))

	var tool_calls: Array = _as_array(message.get("tool_calls", []))
	if not tool_calls.is_empty():
		var call = tool_calls[0]
		if call is Dictionary:
			var fn: Dictionary = _as_dict((call as Dictionary).get("function", {}))
			var name: String = String(fn.get("name", ""))
			if LAActionRegistry.is_valid(name):
				return name

	# Fallback: some servers return the call as plain text. Match a real TOKEN, not a bare substring — require a
	# word boundary before and a boundary or '(' after — so "head to the nearest water" no longer matches "rest"
	# inside "nea-rest", and multi-action text picks the EARLIEST call by position (not ACTIONS order).
	var content: String = String(message.get("content", "")).to_lower()
	if content != "":
		var best_pos: int = 0x7fffffff
		var best_action: String = ""
		for action in LAActionRegistry.ACTIONS:
			var name_l: String = String(action).to_lower()
			var from: int = 0
			while true:
				var p: int = content.find(name_l, from)
				if p < 0:
					break
				var before_ok: bool = p == 0 or not _is_word_char(content[p - 1])
				var ae: int = p + name_l.length()
				var after_ok: bool = ae >= content.length() or content[ae] == "(" or not _is_word_char(content[ae])
				if before_ok and after_ok:
					if p < best_pos:
						best_pos = p
						best_action = String(action)
					break
				from = p + 1
		if best_action != "":
			return best_action
	return ""


static func _is_word_char(ch: String) -> bool:
	return ch == "_" or (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9")


static func _as_array(v) -> Array:
	if v is Array:
		return v as Array
	return []


static func _as_dict(v) -> Dictionary:
	if v is Dictionary:
		return v as Dictionary
	return {}
