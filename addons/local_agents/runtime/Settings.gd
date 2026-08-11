@tool
extends RefCounted
class_name LocalAgentSettings

## The one registry of Local Agents project settings.
##
## `plugin.gd` registers every entry in SPECS with ProjectSettings (typed hints and all), and every
## consumer reads back through the typed getters below. Adding a setting is one record here, never a
## `ProjectSettings.get_setting()` literal sprinkled at a call site.
##
## Resolution order is **ProjectSetting -> environment variable -> default**. The env vars stay working
## because CI and the harness scripts set them; a designer gets a typed row in Project Settings instead
## of an undocumented `LA_*` string.
##
## Only settings that something actually reads live here. Registering knobs nothing consumes is worse
## than not registering them, because it promises control that does not exist.
##
## (Explicit types only. Project rule: no ':=' inferred typing.)

## name        : the ProjectSettings key
## type        : Variant.Type used for the property info
## hint/hint_string : inspector hint so Project Settings renders a file picker / enum / plain field
## default     : value used when neither the setting nor the env var is present
## env         : optional environment-variable override, "" for none
## doc         : one line explaining what it does (mirrored into docs/INSTALL.md)
const SPECS: Array = [
	{
		"name": "local_agents/model/default_path",
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_GLOBAL_FILE,
		"hint_string": "*.gguf",
		"default": "",
		"env": "",
		"doc": "GGUF every LocalAgent falls back to when its own model_path is empty. Blank = search the paths below.",
	},
	{
		"name": "local_agents/model/search_paths",
		"type": TYPE_PACKED_STRING_ARRAY,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "",
		# A plain Array, not PackedStringArray(...): a constructor call is not a constant expression,
		# so it cannot appear inside a const. get_string_array() converts on the way out.
		"default": [
			"user://local_agents/models/qwen3-4b-instruct/Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
			"user://local_agents/models/qwen3-1_7b/Qwen3-1.7B-Q4_K_M.gguf",
			"user://local_agents/models/qwen3-0_6b-instruct/Qwen3-0.6B-Q4_K_M.gguf",
		],
		"env": "",
		"doc": "Ordered GGUF candidates tried when no explicit model path is set. First existing file wins.",
	},
	{
		"name": "local_agents/llm/server_url",
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "",
		"default": "http://127.0.0.1:8080",
		"env": "FUNCTIONGEMMA_URL",
		"doc": "Base URL of the llama-server the shared LlmService talks to.",
	},
	{
		"name": "local_agents/llm/backend",
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "llama_server,in_process",
		"default": "llama_server",
		"env": "",
		"doc": "How inference runs: an external llama-server process, or in-process via the native runtime.",
	},
	{
		"name": "local_agents/llm/auto_enable_when_model_present",
		"type": TYPE_BOOL,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "",
		"default": false,
		"env": "",
		"doc": "Bring the shared LlmService online automatically once a model is installed. Off by default so the addon never boots a server behind the player's back.",
	},
	{
		"name": "local_agents/runtime/fail_fast",
		"type": TYPE_BOOL,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "",
		"default": true,
		"env": "",
		"doc": "Report a missing native runtime or model as an error instead of a warning. Turn off to let a build run silently degraded.",
	},
	{
		"name": "local_agents/editor/enabled",
		"type": TYPE_BOOL,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "",
		"default": false,
		"env": "",
		"doc": "Auto-open the Local Agents bottom panel on editor start. Set by the panel's own Activate button.",
	},
]


## Every spec, for plugin.gd's registration pass and the docs generator.
static func specs() -> Array:
	return SPECS


static func _spec(name: String) -> Dictionary:
	for entry_variant in SPECS:
		var entry: Dictionary = entry_variant
		if String(entry["name"]) == name:
			return entry
	return {}


## ProjectSetting -> env var -> default. Returns the raw Variant; prefer the typed getters below.
static func get_value(name: String) -> Variant:
	var spec: Dictionary = _spec(name)
	if spec.is_empty():
		push_warning("LocalAgentSettings: unknown setting '%s'" % name)
		return null
	var fallback: Variant = spec["default"]
	var value: Variant = ProjectSettings.get_setting(name, null)
	if value != null and not _is_blank(value):
		return value
	var env_name: String = String(spec.get("env", ""))
	if env_name != "" and OS.has_environment(env_name):
		var raw: String = OS.get_environment(env_name).strip_edges()
		if raw != "":
			return _coerce(raw, int(spec["type"]))
	return fallback


static func get_string(name: String) -> String:
	return String(get_value(name))


static func get_bool(name: String) -> bool:
	return bool(get_value(name))


static func get_int(name: String) -> int:
	return int(get_value(name))


static func get_float(name: String) -> float:
	return float(get_value(name))


static func get_string_array(name: String) -> PackedStringArray:
	var value: Variant = get_value(name)
	if value is PackedStringArray:
		return value
	if value is Array:
		var out: PackedStringArray = PackedStringArray()
		for item in value:
			out.append(String(item))
		return out
	return PackedStringArray()


# An unset String setting comes back as "" and an unset array as empty; in both cases we want the
# env var / default to win rather than the empty value. Numbers and bools are never "blank" — 0 and
# false are legitimate choices a user may have made deliberately.
static func _is_blank(value: Variant) -> bool:
	if value is String:
		return String(value).strip_edges() == ""
	if value is PackedStringArray:
		return (value as PackedStringArray).is_empty()
	if value is Array:
		return (value as Array).is_empty()
	return false


static func _coerce(raw: String, type: int) -> Variant:
	match type:
		TYPE_BOOL:
			var lowered: String = raw.to_lower()
			return lowered != "0" and lowered != "false" and lowered != "no" and lowered != "off"
		TYPE_INT:
			return int(raw)
		TYPE_FLOAT:
			return float(raw)
		TYPE_PACKED_STRING_ARRAY:
			return PackedStringArray(raw.split(",", false))
		_:
			return raw
