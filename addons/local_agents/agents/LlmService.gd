@tool
@icon("res://addons/local_agents/icons/local_agent_llm.svg")
class_name LocalAgentLlmService
extends Node


const AgentScript: GDScript = preload("res://addons/local_agents/agents/Agent.gd")
const LlmClientScript: GDScript = preload("res://addons/local_agents/agents/LlmClient.gd")
const RuntimePaths: GDScript = preload("res://addons/local_agents/runtime/RuntimePaths.gd")


const SETTING_AUTO_ENABLE: String = "local_agents/llm/auto_enable_when_model_present"
const SETTING_SERVER_URL: String = "local_agents/llm/server_url"
const SETTING_BACKEND: String = "local_agents/llm/backend"


@export_group("Availability")

## Master switch for the shared local-LLM runtime. Off means is_available() stays false and every
## consumer (the creature slow brain, the streamer) runs its offline path. Off by default so the addon
## never boots a llama-server behind the player's back. Tick it once you have a model installed.
@export var enabled: bool = false

@export_enum("llama_server", "in_process") var backend: String = "llama_server"

@export var log_availability: bool = true

@export_group("Server")

@export_placeholder("http://127.0.0.1:8080") var server_url: String = ""

## Launch llama-server automatically when nothing is answering on the URL above. Turn off to require an
## already-running server (nothing is spawned, and requests simply fail while it is down).
@export var autostart_server: bool = true

## How long to wait for an auto-started llama-server process to come up before giving up on it.
@export_range(1000, 300000, 500, "suffix:ms") var start_timeout_ms: int = 30000

## How long to wait for a server that is already up to report that it is ready to serve requests.
@export_range(200, 60000, 100, "suffix:ms") var ready_timeout_ms: int = 1200

@export_group("Model")

@export_global_file("*.gguf") var model_path: String = ""

## Optional load-time knobs shared by every request: context window, threads, GPU layers, system prompt.
## Leave empty to use the runtime's own defaults.
@export var model_profile: LocalAgentModelProfile

@export var inference: LocalAgentInferenceParams


var _agent: Node = null
var _client = null                       # LocalAgentLlmClient (shared by cognition + streamer)
var _resolved_model: String = ""
var _resolved_server: String = "http://127.0.0.1:8080"
var _resolved_backend: String = "llama_server"
var _available: bool = false
var _offline_reason: String = ""
var _configured: bool = false            # setup() or the _ready() self-configure already ran


## Self-configure from the exports above unless a script already called setup(). Guarded against the
## editor so a @tool node never boots a model server while you are editing the scene.
func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if _configured:
		return
	_configure({})


func setup(options: Dictionary = {}) -> void:
	_configure(options)


# The one configuration path; both setup() and the _ready() self-configure land here. Idempotent: an
# earlier agent/client is torn down first so calling it twice cannot leave two agents parented.
func _configure(options: Dictionary) -> void:
	_configured = true
	_teardown()

	_resolved_backend = String(options.get("backend", backend)).strip_edges()
	if _resolved_backend == "":
		_resolved_backend = LocalAgentSettings.get_string(SETTING_BACKEND)
	_resolved_server = _normalize_url(String(options.get("server_url", _setting_server_url())))
	_resolved_model = resolve_model_path(String(options.get("model_path", model_path)))
	_available = _resolve_availability(options)

	if _available:
		_offline_reason = ""
		_build_agent()
	else:
		_offline_reason = _describe_offline()
	if log_availability:
		print(status_line())


func _resolve_availability(options: Dictionary) -> bool:
	if options.has("enabled"):
		return bool(options["enabled"]) or (options.has("server_url") and _resolved_server != "")
	if options.has("server_url") and _resolved_server != "":
		return true
	if enabled:
		return true
	if OS.get_environment("FUNCTIONGEMMA_URL").strip_edges() != "":
		return true
	return LocalAgentSettings.get_bool(SETTING_AUTO_ENABLE) and _resolved_model != ""


func _build_agent() -> void:
	_agent = AgentScript.new()
	_agent.name = "LlmServiceAgent"
	add_child(_agent)
	# load_options = "which weights, loaded how"; inference_options = "how to sample". The two are kept
	# apart by LocalAgent itself (see _merged_options), so feed each from its own resource.
	var load_options: Dictionary = {}
	if model_profile != null:
		load_options = model_profile.to_options()
	if _resolved_model != "" and not load_options.has("model_path"):
		load_options["model_path"] = _resolved_model
	_agent.load_options = load_options
	if inference != null:
		_agent.inference_options = inference.to_options()
	_client = LlmClientScript.new(_agent, _request_defaults())


func _request_defaults() -> Dictionary:
	var defaults: Dictionary = {"backend": _resolved_backend}
	if _resolved_backend == "llama_server":
		defaults["server_base_url"] = _resolved_server
		defaults["server_autostart"] = autostart_server
		defaults["server_start_timeout_ms"] = start_timeout_ms
		defaults["server_ready_timeout_ms"] = ready_timeout_ms
		if _resolved_model != "":
			defaults["server_model_path"] = _resolved_model
	elif _resolved_model != "":
		defaults["model_path"] = _resolved_model
	return defaults


func _teardown() -> void:
	_client = null
	if _agent != null and is_instance_valid(_agent):
		# Unparent BEFORE queue_free: the free is deferred, so a re-configure would otherwise leave two
		# agents parented (and both connected) for the rest of the frame.
		if _agent.get_parent() == self:
			remove_child(_agent)
		_agent.queue_free()
	_agent = null


func resolve_model_path(preferred: String = "") -> String:
	if preferred.strip_edges() != "":
		return preferred.strip_edges()
	return LocalAgentStatus.resolve_model_path()


func is_available() -> bool:
	return _available and _client != null


## The shared LocalAgentLlmClient (null when offline). Cognition + streamer request through this.
func client():
	return _client


## The GGUF this service resolved to, whether or not it is enabled. "" when nothing is installed.
func resolved_model_path() -> String:
	return _resolved_model


## The llama-server base URL this service resolved to (after trimming any trailing slash).
func resolved_server_url() -> String:
	return _resolved_server


## Why the service is offline, in one sentence with the fix. "" when it is online.
func offline_reason() -> String:
	return _offline_reason


## One line safe to print or drop into a Label: online with what, or offline and why.
func status_line() -> String:
	if is_available():
		var model_name: String = "none"
		if _resolved_model != "":
			model_name = _resolved_model.get_file()
		if _resolved_backend == "llama_server":
			return "LocalAgentLlmService: online, backend=llama_server server=%s model=%s" % [_resolved_server, model_name]
		return "LocalAgentLlmService: online, backend=%s model=%s" % [_resolved_backend, model_name]
	return "LocalAgentLlmService: offline, %s" % _offline_reason


func _describe_offline() -> String:
	if _resolved_model == "":
		var checked: PackedStringArray = LocalAgentStatus.candidate_paths()
		return "no GGUF model found, so consumers run their offline paths. Install one from the Local Agents panel > Downloads, or set local_agents/model/default_path. Checked: %s" % ", ".join(checked)
	return "a model is installed (%s) but the service is switched off, so consumers run their offline paths. Tick 'Enabled' on this node, or turn on the project setting %s." % [_resolved_model.get_file(), SETTING_AUTO_ENABLE]


func _setting_server_url() -> String:
	var from_export: String = server_url.strip_edges()
	if from_export != "":
		return from_export
	return LocalAgentSettings.get_string(SETTING_SERVER_URL).strip_edges()


func _normalize_url(raw: String) -> String:
	var url: String = raw.strip_edges()
	while url.ends_with("/"):
		url = url.substr(0, url.length() - 1)
	return url


func _get_configuration_warnings() -> PackedStringArray:
	var out: PackedStringArray = LocalAgentStatus.warnings_for({"extension": true, "model": true})
	if not enabled and not LocalAgentSettings.get_bool(SETTING_AUTO_ENABLE):
		out.append("This service is disabled, so every consumer (creature cognition, the streamer) will run its offline path. Tick 'Enabled' to bring the shared local LLM online.")
	return out
