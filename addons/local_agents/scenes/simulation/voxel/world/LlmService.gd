class_name LALlmService
extends Node

## The ONE shared owner of the local-LLM runtime for the whole sim. It holds a single LocalAgent (the
## in-process / llama-server primitive), resolves the model path + server URL in ONE place
## (RuntimePaths + the chat-model candidates the streamer used to resolve privately), and hands out a
## single shared LocalAgentLlmClient. The creature slow brain (LACognitionScheduler) and the streamer
## commentator (LAStreamerDirector) both talk through this one client → one server, one model, one config.
##
## This is the collapse of the three forked chat-completions paths: cognition's raw HTTPRequest client,
## the streamer's private HTTPRequest client + private server manager + private model resolution, and the
## standalone agent's native path are now the SAME LocalAgent behind this service.
##
## When no model is present AND no server URL was explicitly configured it reports is_available()==false;
## callers then run their offline paths (the heuristic teacher / canned-silent streamer), exactly as before.
##
## (Explicit types only — project rule: no ':=' inferred typing.)

const AgentScript: GDScript = preload("res://addons/local_agents/agents/Agent.gd")
const LlmClientScript: GDScript = preload("res://addons/local_agents/agents/LlmClient.gd")
const RuntimePaths: GDScript = preload("res://addons/local_agents/runtime/RuntimePaths.gd")

# Chat/instruct model candidates, resolved in order after RuntimePaths' own default. This is the same
# list StreamerDirector used to resolve privately — now the ONE resolution owner. A capable instruct
# model serves BOTH the streamer chat and the creature function-calls, so there is one server + one
# model for the whole session.
const MODEL_CANDIDATES: Array = [
	"user://local_agents/models/qwen3-1_7b/Qwen3-1.7B-Q4_K_M.gguf",
	"user://local_agents/models/qwen3-0_6b-instruct/Qwen3-0.6B-Q4_K_M.gguf",
	"user://local_agents/models/qwen3-4b-instruct/Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
]

var _agent: Node = null
var _client = null                       # LocalAgentLlmClient (shared by cognition + streamer)
var _model_path: String = ""
var _server_url: String = "http://127.0.0.1:8080"
var _backend: String = "llama_server"
var _available: bool = false


## Resolve model + server once, then build the shared LocalAgent + client. Options:
##   server_url : llama-server base URL (e.g. env FUNCTIONGEMMA_URL); default 127.0.0.1:8080.
##   enabled    : force-enable even without a server_url (e.g. for the in_process backend).
##   model_path : explicit gguf; otherwise resolved from RuntimePaths + MODEL_CANDIDATES.
##   backend    : "llama_server" (default) or "in_process".
##
## Availability is OPT-IN: without an explicit server_url (or enabled:true) the service stays offline and
## every consumer runs its heuristic/teacher path — the mere presence of a model file on disk does NOT
## silently switch the sim onto the LLM (that would change behaviour + boot a server behind the player's
## back). This mirrors the old FUNCTIONGEMMA_URL gate, now unified through the one LocalAgent.
func setup(options: Dictionary = {}) -> void:
	_backend = String(options.get("backend", "llama_server"))
	_server_url = String(options.get("server_url", "http://127.0.0.1:8080")).strip_edges()
	while _server_url.ends_with("/"):
		_server_url = _server_url.substr(0, _server_url.length() - 1)
	_model_path = resolve_model_path(String(options.get("model_path", "")))

	var has_server_override: bool = options.has("server_url") and _server_url != ""
	var force_enabled: bool = bool(options.get("enabled", false))
	_available = has_server_override or force_enabled
	if not _available:
		return

	_agent = AgentScript.new()
	_agent.name = "LlmServiceAgent"
	add_child(_agent)
	var defaults: Dictionary = {"backend": _backend}
	if _backend == "llama_server":
		defaults["server_base_url"] = _server_url
		if _model_path != "":
			defaults["server_model_path"] = _model_path
	_client = LlmClientScript.new(_agent, defaults)


## The single model-resolution owner: an explicit path wins, else RuntimePaths' default, else the
## chat-model candidate list. Returns "" when nothing is installed.
func resolve_model_path(preferred: String = "") -> String:
	if preferred.strip_edges() != "":
		return preferred.strip_edges()
	var runtime_default: String = RuntimePaths.resolve_default_model()
	if runtime_default != "":
		return runtime_default
	for c in MODEL_CANDIDATES:
		if FileAccess.file_exists(ProjectSettings.globalize_path(String(c))):
			return String(c)
	return ""


func is_available() -> bool:
	return _available and _client != null


## The shared LocalAgentLlmClient (null when offline). Cognition + streamer request through this.
func client():
	return _client


func model_path() -> String:
	return _model_path
