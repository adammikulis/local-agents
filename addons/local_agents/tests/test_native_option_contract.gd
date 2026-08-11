@tool
extends RefCounted

## The GDScript <-> native option contract: every knob the inspector shows must survive both hops to
## the runtime that actually reads it.
##
## The most repeated defect in this addon was a DEAD EXPORT - a property declared, documented and
## plumbed through GDScript that nothing on the far side ever reads. Four shipped that way
## (system_prompt, max_actions_per_tick, db_path, model_profile.threads) and only a live model run
## disproved the first. Nothing tested it. This does, in two hops:
##
##   HOP 1  export -> option key.  Every editor-exported property of LocalAgentModelProfile and
##          LocalAgentInferenceParams must appear in that resource's to_options() output, under its
##          own name or under a declared alias. A knob added to the inspector and never plumbed into
##          to_options() fails here.
##
##   HOP 2  option key -> consumer.  Every key to_options() emits must be looked up in the native
##          runtime source (addons/local_agents/gdextensions/localagents/src/). A key nothing looks
##          up is DEAD: the user sets it, the runtime never sees it.
##
## Seven keys are natively unconsumed TODAY, so hop 2 would fail on a healthy tree. They are listed
## in KNOWN_UNCONSUMED with a reason, and the list is CHECKED rather than trusted:
##   - a KNOWN_UNCONSUMED key that the native source HAS started reading fails the test (stale entry
##     -> delete it), so the list cannot silently rot;
##   - a key documented as GDSCRIPT_CONSUMED must actually be looked up somewhere in the addon's
##     GDScript, and a key documented as RESERVED must be looked up NOWHERE.
## The point of the list is that the NEXT dead key is a test failure rather than a discovery.
##
## What counts as "looked up" is deliberately narrow - reads only, so that WRITING a key
## (`opts["system_prompt"] = system_prompt`, which is exactly what the dead system_prompt export
## does) is never mistaken for consuming it:
##   <ident>.has("<key>")   <ident>.get("<key>"   <ident>.get_or_add("<key>"
## plus, in the native source only, the request-body helper `copy_if_present("<key>", ...)` whose
## body is `if (options.has(option_key)) { payload[payload_key] = options[option_key]; }`
## (AgentRuntime.cpp, the lambda declared just above the copy_if_present block).
##
## (Explicit types only - project rule: no ':=' inferred typing.)

const NATIVE_SRC_DIR: String = "res://addons/local_agents/gdextensions/localagents/src/"
const ADDON_ROOT: String = "res://addons/local_agents/"
const NATIVE_SRC_SUFFIXES: Array[String] = [".cpp", ".h", ".hpp"]

# Reason codes for KNOWN_UNCONSUMED. Both are verified, not just documented - see _check_known_entry.
const GDSCRIPT_CONSUMED: String = "gdscript"   # the addon's GDScript reads it; the native runtime does not
const RESERVED: String = "reserved"            # nothing reads it anywhere; kept for a documented reason

## Option keys the native runtime does NOT read today. Every entry is deliberate; adding one is how
## you declare a knob reserved, and the test refuses to let an entry outlive its reason.
##
##   threads                  - the in-process runtime picks its own thread count; this value is only
##                              passed to the managed llama-server process (LlamaServerManager).
##   system_prompt            - RESERVED. The runtime keeps ONE system_prompt_ on the shared
##                              AgentRuntime singleton, so a per-agent prompt cannot travel in the
##                              options at all; LocalAgent puts it at history[0] instead (see
##                              LocalAgentAgentHistory.apply_system_prompt). The key is still emitted
##                              because a profile may legitimately describe one.
##   chat_template            - RESERVED. Overriding the GGUF's baked-in template is not wired to any
##                              backend yet; the profile carries the value so scenes do not lose it.
##   server_autostart         - llama-server process lifecycle, owned by LocalAgentAgentServer.
##   server_shutdown_on_exit  - llama-server process lifecycle, owned by LocalAgentAgentServer.
##   server_start_timeout_ms  - llama-server process lifecycle, owned by LlamaServerManager.
##   server_ready_timeout_ms  - llama-server process lifecycle, owned by LlamaServerManager.
const KNOWN_UNCONSUMED: Dictionary = {
	"threads": GDSCRIPT_CONSUMED,
	"system_prompt": RESERVED,
	"chat_template": RESERVED,
	"server_autostart": GDSCRIPT_CONSUMED,
	"server_shutdown_on_exit": GDSCRIPT_CONSUMED,
	"server_start_timeout_ms": GDSCRIPT_CONSUMED,
	"server_ready_timeout_ms": GDSCRIPT_CONSUMED,
}

# HOP 1 tables. An export either maps to an option key of the same name, or is listed here.
const PROFILE_ALIASES: Dictionary = {
	"gpu_layers": "n_gpu_layers",
}
const PARAMS_ALIASES: Dictionary = {
	"mirostat_mode": "mirostat",
	"server_slot": "id_slot",
	"server_cache_prompt": "cache_prompt",
}
## Exports that are NOT options, with the reason each one is exempt.
##   profile_name / inference_config_name - cosmetic labels, shown in preset lists only.
##   model_path                           - argument 1 of AgentRuntime.load_model(model_path, options),
##                                          not a member of `options`. Asserted below against the
##                                          runtime's own binding metadata.
##   extra_options                        - the merge escape hatch; its CONTENTS become keys, it is
##                                          never a key itself.
const PROFILE_NON_OPTION: Array[String] = ["profile_name", "model_path"]
const PARAMS_NON_OPTION: Array[String] = ["inference_config_name", "extra_options"]

var _failures: Array[String] = []


func run_test(_tree: SceneTree) -> bool:
	_failures.clear()

	var native_src: String = _read_dir_text(NATIVE_SRC_DIR, NATIVE_SRC_SUFFIXES)
	if native_src.strip_edges() == "":
		# A hard failure, never a skip: with no native source to grep, this test proves nothing.
		push_error("Native runtime source not found under %s; the option contract cannot be checked." % NATIVE_SRC_DIR)
		return false
	var gdscript_src: String = _read_addon_gdscript()

	var profile: LocalAgentModelProfile = _populated_profile()
	var params: LocalAgentInferenceParams = _populated_params()
	var profile_options: Dictionary = profile.to_options()
	var params_options: Dictionary = params.to_options()

	_check_exports_reach_options("LocalAgentModelProfile", profile, profile_options, PROFILE_ALIASES, PROFILE_NON_OPTION)
	_check_exports_reach_options("LocalAgentInferenceParams", params, params_options, PARAMS_ALIASES, PARAMS_NON_OPTION)

	var emitted: Array[String] = []
	for key in profile_options.keys():
		if not emitted.has(String(key)):
			emitted.append(String(key))
	for key in params_options.keys():
		if not emitted.has(String(key)):
			emitted.append(String(key))
	if emitted.is_empty():
		_fail("to_options() emitted no keys at all; the populated resources are wrong.")

	for key in emitted:
		_check_key_consumed(key, native_src, gdscript_src)
	for key in KNOWN_UNCONSUMED.keys():
		var known: String = String(key)
		if not emitted.has(known):
			_fail("KNOWN_UNCONSUMED lists '%s', but no to_options() emits it any more. Delete the entry." % known)

	_check_load_model_binding()

	if _failures.is_empty():
		print("Native option contract: %d emitted keys checked, %d documented as unconsumed." % [emitted.size(), KNOWN_UNCONSUMED.size()])
		return true
	for line in _failures:
		push_error(line)
	return false


# --- hop 1: export -> option key -------------------------------------------------------------------

func _check_exports_reach_options(label: String, res: Resource, options: Dictionary, aliases: Dictionary, non_option: Array[String]) -> void:
	var exports: Array[String] = _exported_property_names(res)
	if exports.is_empty():
		_fail("%s exposes no exported properties; the export scan is broken." % label)
		return
	for property_name in exports:
		if non_option.has(property_name):
			continue
		var key: String = String(aliases.get(property_name, property_name))
		if not options.has(key):
			_fail("%s.%s is exported but to_options() emits no '%s' key - a DEAD export. Plumb it into to_options(), add an alias, or list it as a non-option export." % [label, property_name, key])
	for alias_key in aliases.keys():
		var alias_name: String = String(alias_key)
		if not exports.has(alias_name):
			_fail("%s alias '%s' -> '%s' names a property that no longer exists. Delete the alias." % [label, alias_name, String(aliases[alias_key])])
	for exempt in non_option:
		if not exports.has(exempt):
			_fail("%s non-option export '%s' no longer exists. Delete the entry." % [label, exempt])


# --- hop 2: option key -> consumer -----------------------------------------------------------------

func _check_key_consumed(key: String, native_src: String, gdscript_src: String) -> void:
	var native: bool = _is_looked_up(native_src, key, true)
	if not KNOWN_UNCONSUMED.has(key):
		if not native:
			_fail("Option key '%s' is emitted by to_options() but nothing in %s looks it up - it is DEAD. Consume it natively, or add it to KNOWN_UNCONSUMED with a reason." % [key, NATIVE_SRC_DIR])
		return
	_check_known_entry(key, native, gdscript_src)


func _check_known_entry(key: String, native: bool, gdscript_src: String) -> void:
	if native:
		_fail("KNOWN_UNCONSUMED lists '%s', but the native runtime now looks it up. Delete the entry - the key is alive." % key)
		return
	var reason: String = String(KNOWN_UNCONSUMED[key])
	var in_gdscript: bool = _is_looked_up(gdscript_src, key, false)
	if reason == GDSCRIPT_CONSUMED and not in_gdscript:
		_fail("KNOWN_UNCONSUMED says '%s' is read by the addon's GDScript, but no .has()/.get() lookup of it exists there either. It is fully dead - fix it or mark it RESERVED." % key)
	elif reason == RESERVED and in_gdscript:
		_fail("KNOWN_UNCONSUMED marks '%s' RESERVED, but the addon's GDScript now looks it up. Change the reason to GDSCRIPT_CONSUMED." % key)
	elif reason != GDSCRIPT_CONSUMED and reason != RESERVED:
		_fail("KNOWN_UNCONSUMED entry '%s' has an unknown reason '%s'." % [key, reason])


# The runtime entry point every model load goes through. LocalAgentStatus.load_model() calling it with
# the path ALONE - one argument instead of two - is a shipped bug this pins down: the binding declares
# two required parameters and no default, so a one-argument call cannot work.
func _check_load_model_binding() -> void:
	if not ClassDB.class_exists("AgentRuntime"):
		_fail("AgentRuntime class is not registered; the native extension did not load.")
		return
	var found: bool = false
	for method_variant in ClassDB.class_get_method_list("AgentRuntime", true):
		var method: Dictionary = method_variant
		if String(method.get("name", "")) != "load_model":
			continue
		found = true
		var args: Array = method.get("args", [])
		var defaults: Array = method.get("default_args", [])
		if args.size() != 2:
			_fail("AgentRuntime.load_model is bound with %d argument(s); the contract is (model_path, options)." % args.size())
		else:
			var first: String = String((args[0] as Dictionary).get("name", ""))
			var second: String = String((args[1] as Dictionary).get("name", ""))
			if first != "model_path" or second != "options":
				_fail("AgentRuntime.load_model arguments are (%s, %s); expected (model_path, options)." % [first, second])
		if not defaults.is_empty():
			_fail("AgentRuntime.load_model now has %d default argument(s); a one-argument call would silently become legal." % defaults.size())
	if not found:
		_fail("AgentRuntime exposes no load_model method.")


# --- helpers ---------------------------------------------------------------------------------------

# Every conditional branch of to_options() is forced open, so the emitted set is the FULL surface
# rather than whatever a default-constructed resource happens to send. extra_options stays empty on
# purpose: its contents are user-defined and are not part of the contract.
func _populated_profile() -> LocalAgentModelProfile:
	var profile: LocalAgentModelProfile = LocalAgentModelProfile.new()
	profile.profile_name = "contract"
	profile.model_path = "/tmp/local_agents_contract.gguf"
	profile.context_size = 2048
	profile.threads = 4
	profile.gpu_layers = 1
	profile.system_prompt = "contract system prompt"
	profile.chat_template = "{{ messages }}"
	return profile


func _populated_params() -> LocalAgentInferenceParams:
	var params: LocalAgentInferenceParams = LocalAgentInferenceParams.new()
	params.inference_config_name = "contract"
	params.seed = 1
	params.backend = "llama_server"
	params.server_base_url = "http://127.0.0.1:8080"
	params.server_api_key = "contract-key"
	params.server_model = "contract-model"
	params.server_slot = 0
	params.server_extra_body = {"contract": true}
	return params


func _exported_property_names(res: Resource) -> Array[String]:
	var out: Array[String] = []
	for property_variant in res.get_property_list():
		var property: Dictionary = property_variant
		var usage: int = int(property.get("usage", 0))
		if usage & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		if usage & PROPERTY_USAGE_EDITOR == 0:
			continue
		out.append(String(property.get("name", "")))
	return out


# READ forms only - a write (`opts["key"] = value`) must never count as consumption.
func _is_looked_up(haystack: String, key: String, native: bool) -> bool:
	var pattern: String = "[A-Za-z_][A-Za-z0-9_]*\\s*\\.\\s*(has|get|get_or_add)\\s*\\(\\s*\"%s\"" % key
	if native:
		pattern += "|copy_if_present\\s*\\(\\s*\"%s\"" % key
	var regex: RegEx = RegEx.new()
	if regex.compile(pattern) != OK:
		_fail("Failed to compile the lookup pattern for '%s'." % key)
		return true          # never fail a key because the test's own regex broke
	return regex.search(haystack) != null


func _read_dir_text(dir_path: String, suffixes: Array[String]) -> String:
	var out: String = ""
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			for suffix in suffixes:
				if entry.ends_with(suffix):
					out += _read_file(dir_path + entry) + "\n"
					break
		entry = dir.get_next()
	dir.list_dir_end()
	return out


# Every .gd in the addon EXCEPT tests/ - so this file's own KNOWN_UNCONSUMED table can never make a
# key look consumed - and except configuration/parameters/, which is the emitting side.
func _read_addon_gdscript() -> String:
	var out: String = ""
	var pending: Array[String] = [ADDON_ROOT]
	while not pending.is_empty():
		var current: String = String(pending.pop_back())
		var dir: DirAccess = DirAccess.open(current)
		if dir == null:
			continue
		dir.list_dir_begin()
		var entry: String = dir.get_next()
		while entry != "":
			var path: String = current + entry
			if dir.current_is_dir():
				if entry != "tests" and entry != "parameters" and not entry.begins_with("."):
					pending.append(path + "/")
			elif entry.ends_with(".gd"):
				out += _read_file(path) + "\n"
			entry = dir.get_next()
		dir.list_dir_end()
	return out


func _read_file(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text: String = file.get_as_text()
	file.close()
	return text


func _fail(message: String) -> void:
	if not _failures.has(message):
		_failures.append(message)
