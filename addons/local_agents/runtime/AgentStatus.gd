@tool
extends RefCounted
class_name LocalAgentStatus

## The ONE answer to "is Local Agents ready, and if not, what do I do about it?"
##
## Before this existed the same probe was reimplemented four times — twice through private API
## (`agent.agent_node.load_model()`, `Engine.get_singleton("AgentRuntime")` reflection) — in
## AgentQuickstart, Agent3DExample, ChatController and the old RuntimeHealth helper (now deleted).
## Every one of them phrased the
## failure differently and none of them told the user how to fix it.
##
## `check()` returns a fixed-shape Dictionary: the keys below are ALWAYS present, so a caller never
## has to branch on absence. `blockers` is ordered by fix order (you cannot load a model without the
## extension), which is what lets `next_step()` be a single sentence and lets a UI render a checklist
## without knowing anything about the runtime.
##
## (Explicit types only — project rule: no ':=' inferred typing.)

const ExtensionLoader: GDScript = preload("res://addons/local_agents/runtime/LocalAgentExtensionLoader.gd")
const RuntimePaths: GDScript = preload("res://addons/local_agents/runtime/RuntimePaths.gd")
const Settings: GDScript = preload("res://addons/local_agents/runtime/Settings.gd")
# Safe to preload: SpeechEngine only preloads RuntimePaths, so there is no cycle back to here.
const SpeechEngine: GDScript = preload("res://addons/local_agents/runtime/audio/SpeechEngine.gd")

enum Level {
	READY,     ## Everything needed to generate text is present.
	DEGRADED,  ## Generation works, but part of the addon's own runtime is missing (speech).
	BLOCKED,   ## Generation cannot happen at all.
}

# Blockers — ordered by the order you must fix them in.
const BLOCK_EXTENSION_MISSING: String = "extension_missing"
const BLOCK_AUTOLOAD_MISSING: String = "autoload_missing"
const BLOCK_MODEL_MISSING: String = "model_missing"
const BLOCK_MODEL_NOT_LOADED: String = "model_not_loaded"

# Warnings — never gate generation. Some of these also do not lower `level`; see LEVEL_WARNINGS.
const WARN_SPEECH_MISSING: String = "speech_runtime_missing"
const WARN_VOXEL_MISSING: String = "voxel_backend_missing"

# Which warnings are bad enough to knock the headline down to DEGRADED.
#
# Speech is: Piper ships with the addon, so a missing speech runtime means the addon's own install is
# incomplete and say() will not work. The voxel backend is NOT: addons/zylann.voxel/ is an optional
# third-party dependency that only LocalAgentSimWorld in SPHERE mode needs, and most consumers install
# this addon to talk to a model and will never want it. Folding it into `level` made a fully working
# chat install report "ready, 1 optional feature(s) unavailable" permanently, which is noise.
#
# WARN_VOXEL_MISSING is still reported in `warnings`, so a node that genuinely needs the backend
# surfaces it through warnings_for_state(state, needs) — which is the right place for a need only the
# node knows about.
# A plain Array, not PackedStringArray(...): a constructor call is not a constant expression.
const LEVEL_WARNINGS: Array = [WARN_SPEECH_MISSING]

const _FIX: Dictionary = {
	BLOCK_EXTENSION_MISSING:
		"The Local Agents native extension is not loaded. Build it with scripts/build_extension.sh, or drop a CI artifact into addons/local_agents/gdextensions/localagents/bin/.",
	BLOCK_AUTOLOAD_MISSING:
		"The AgentManager autoload is missing. Re-enable the Local Agents plugin (it registers the autoload), or add it by hand in Project Settings > Autoload.",
	BLOCK_MODEL_MISSING:
		"No GGUF model found. Open the Local Agents bottom panel > Downloads and fetch one, or point local_agents/model/default_path at a .gguf you already have.",
	BLOCK_MODEL_NOT_LOADED:
		"A model file is present but not loaded yet. Call LocalAgentStatus.ensure_model_loaded(), or turn on 'Preload Model' on the LocalAgent node.",
}


## The full picture. Every key listed here is always present.
static func check() -> Dictionary:
	var extension_ok: bool = ExtensionLoader.ensure_initialized()
	var extension_error: String = ExtensionLoader.get_error()
	var autoload_ok: bool = _autoload_present()
	var model_path: String = resolve_model_path()
	var model_candidates: PackedStringArray = candidate_paths()
	var model_loaded: bool = _model_loaded()
	var speech_ok: bool = _speech_ok()
	var voxel_ok: bool = ClassDB.class_exists("VoxelLodTerrain")

	var blockers: PackedStringArray = PackedStringArray()
	if not extension_ok:
		blockers.append(BLOCK_EXTENSION_MISSING)
	if not autoload_ok:
		blockers.append(BLOCK_AUTOLOAD_MISSING)
	if model_path == "":
		blockers.append(BLOCK_MODEL_MISSING)
	elif extension_ok and not model_loaded:
		blockers.append(BLOCK_MODEL_NOT_LOADED)

	var warnings: PackedStringArray = PackedStringArray()
	if not speech_ok:
		warnings.append(WARN_SPEECH_MISSING)
	if not voxel_ok:
		warnings.append(WARN_VOXEL_MISSING)

	var level: int = Level.READY
	if not blockers.is_empty():
		level = Level.BLOCKED
	else:
		for warning in warnings:
			if LEVEL_WARNINGS.has(warning):
				level = Level.DEGRADED
				break

	return {
		"level": level,
		"ready": level == Level.READY,
		"headline": _headline_for(level, blockers, warnings, model_path),
		"next_step": "" if blockers.is_empty() else String(_FIX.get(blockers[0], "")),
		"blockers": blockers,
		"warnings": warnings,
		"extension_ok": extension_ok,
		"extension_error": extension_error,
		"expected_library_path": expected_library_path(),
		"autoload_ok": autoload_ok,
		"model_path": model_path,
		"model_candidates": model_candidates,
		"model_loaded": model_loaded,
		"runtime_dir": RuntimePaths.runtime_dir(),
		"speech_ok": speech_ok,
		"voxel_backend_ok": voxel_ok,
	}


static func is_ready() -> bool:
	return bool(check()["ready"])


## One line, safe to drop straight into a Label.
static func headline() -> String:
	return String(check()["headline"])


## One actionable sentence for the topmost blocker, or "" when nothing is blocking.
static func next_step() -> String:
	return String(check()["next_step"])


## Which weights are currently resident. "" means nothing loaded, or something loaded them behind
## this module's back — which is why load_model() below is the only sanctioned loader.
static var _resident_path: String = ""
static var _load_lock: Mutex = Mutex.new()


## THE one place a model is loaded.
##
## AgentRuntime::load_model always unload_model_locked()s and reloads from disk (AgentRuntime.cpp:1845)
## — it never short-circuits on an already-resident path — so callers must not invoke it
## speculatively, and "what is resident" has to be tracked. Tracking it in more than one place is
## how an agent ends up silently generating on someone else's weights: a per-node cache went stale
## the moment any other path loaded a model, and there were five such paths.
##
## Returns true when `path` is resident afterwards.
static func load_model(path: String, options: Dictionary = {}) -> bool:
	if path == "":
		return false
	var runtime: Object = _runtime()
	if runtime == null or not runtime.has_method("load_model"):
		return false
	_load_lock.lock()
	if _resident_path == path and _model_loaded():
		_load_lock.unlock()
		return true
	# Two arguments: load_model is bound as (model_path, options). Calling it with the path alone
	# silently fails, which left the chat panel, the conversation driver and three demos unable to
	# generate on an otherwise healthy install.
	var ok: bool = bool(runtime.call("load_model", path, options))
	_resident_path = path if ok else ""
	_load_lock.unlock()
	return ok


## The path load_model() believes is resident, or "" if nothing is.
static func resident_model_path() -> String:
	return _resident_path


## Load the project's resolved model if nothing is loaded yet. Absorbs the private-API poking
## (`agent.agent_node.load_model()`) that three demos each reimplemented.
## `options` carries the load-time knobs (context size, GPU layers).
static func ensure_model_loaded(options: Dictionary = {}) -> bool:
	if not ExtensionLoader.ensure_initialized():
		return false
	if _model_loaded() and _resident_path != "":
		return true
	return load_model(resolve_model_path(), options)


## Editor-facing warning strings for `_get_configuration_warnings()`. `needs` selects which checks
## apply to this node, e.g. {"model": true, "autoload": true} — so each node's implementation stays a
## one-line forwarder instead of growing its own copy of this logic.
static func warnings_for(needs: Dictionary) -> PackedStringArray:
	return warnings_for_state(check(), needs)


## Same as warnings_for(), against a state you already have. check() re-probes the filesystem, the
## ClassDB and the extension loader every call, so a UI drawing several rows per tick should call
## check() once and pass the result here rather than paying for it per row.
static func warnings_for_state(state: Dictionary, needs: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if bool(needs.get("extension", true)) and not bool(state["extension_ok"]):
		out.append("%s\nExpected: %s" % [String(_FIX[BLOCK_EXTENSION_MISSING]), String(state["expected_library_path"])])
	if bool(needs.get("autoload", false)) and not bool(state["autoload_ok"]):
		out.append(String(_FIX[BLOCK_AUTOLOAD_MISSING]))
	if bool(needs.get("model", false)) and String(state["model_path"]) == "":
		out.append("%s\nChecked: %s" % [String(_FIX[BLOCK_MODEL_MISSING]), ", ".join(state["model_candidates"])])
	if bool(needs.get("speech", false)) and not bool(state["speech_ok"]):
		out.append("Speech is requested but the Piper voice runtime is missing, so nothing will be spoken aloud.")
	if bool(needs.get("voxel", false)) and not bool(state["voxel_backend_ok"]):
		out.append("This needs the godot_voxel GDExtension (addons/zylann.voxel/), which is not installed.")
	return out


## The GGUF this project resolves to: the explicit default setting first, then each search path in
## order. "" when nothing is installed. This is the ONE model-resolution owner.
static func resolve_model_path() -> String:
	var explicit: String = Settings.get_string("local_agents/model/default_path").strip_edges()
	if explicit != "" and _file_exists(explicit):
		return explicit
	var runtime_default: String = RuntimePaths.resolve_default_model()
	if runtime_default != "":
		return runtime_default
	for candidate in Settings.get_string_array("local_agents/model/search_paths"):
		var path: String = String(candidate).strip_edges()
		if path != "" and _file_exists(path):
			return path
	return ""


## Everything resolve_model_path() would try, in order — for "checked: ..." error messages.
static func candidate_paths() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var explicit: String = Settings.get_string("local_agents/model/default_path").strip_edges()
	if explicit != "":
		out.append(explicit)
	for candidate in RuntimePaths.default_model_candidates():
		out.append(String(candidate))
	for candidate in Settings.get_string_array("local_agents/model/search_paths"):
		if not out.has(String(candidate)):
			out.append(String(candidate))
	return out


static func expected_library_path() -> String:
	var os_name: String = OS.get_name()
	var base: String = "res://addons/local_agents/gdextensions/localagents/bin/localagents"
	if os_name == "macOS":
		return "%s.macos.dylib" % base
	if os_name == "Linux":
		return "%s.linux.so" % base
	if os_name == "Windows":
		return "%s.windows.dll" % base
	return ""


static func _headline_for(level: int, blockers: PackedStringArray, warnings: PackedStringArray, model_path: String) -> String:
	if level == Level.BLOCKED:
		match blockers[0]:
			BLOCK_EXTENSION_MISSING:
				return "Local Agents: native runtime unavailable"
			BLOCK_AUTOLOAD_MISSING:
				return "Local Agents: AgentManager autoload missing"
			BLOCK_MODEL_MISSING:
				return "Local Agents: no model installed"
			BLOCK_MODEL_NOT_LOADED:
				return "Local Agents: model found, not loaded yet"
			_:
				return "Local Agents: not ready"
	var name: String = model_path.get_file()
	if level == Level.DEGRADED:
		# Only the warnings that set the level are named here, so the headline matches the reason.
		# `warnings` can also carry advisory entries that leave the level at READY.
		if warnings.has(WARN_SPEECH_MISSING):
			return "Local Agents: ready (%s), but speech is unavailable" % name
		return "Local Agents: ready (%s), with some features unavailable" % name
	return "Local Agents: ready (%s)" % name


static func _runtime() -> Object:
	if not Engine.has_singleton("AgentRuntime"):
		return null
	return Engine.get_singleton("AgentRuntime")


static func _model_loaded() -> bool:
	var runtime: Object = _runtime()
	if runtime == null or not runtime.has_method("is_model_loaded"):
		return false
	return bool(runtime.call("is_model_loaded"))


## Can this install actually say something out loud, by any route.
##
## This used to ask the native runtime whether a `piper` BINARY was present, and nothing else. The
## addon does not ship that binary, so the answer was false on every stock install, which reported a
## fully working setup as degraded forever. Speech really runs through SpeechEngine, which tries the
## binary, then the piper Python module, then the system voice, so that is the question to ask.
static func _speech_ok() -> bool:
	return SpeechEngine.speech_available(RuntimePaths.runtime_dir())


# In the EDITOR, check the project setting rather than the scene tree. The editor does have a
# SceneTree, but a non-@tool autoload script (AgentManager.gd is not @tool) is never instantiated
# into the editor's root — so has_node() reports false even when the autoload is correctly
# registered, which showed a permanently red, unfixable row in the Setup tab.
static func _autoload_present() -> bool:
	if Engine.is_editor_hint():
		return ProjectSettings.has_setting("autoload/AgentManager")
	var loop: MainLoop = Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		return true
	var root: Window = (loop as SceneTree).root
	if root == null:
		return true
	return root.has_node("AgentManager")


static func _file_exists(path: String) -> bool:
	var normalized: String = RuntimePaths.normalize_path(path)
	return normalized != "" and FileAccess.file_exists(normalized)
