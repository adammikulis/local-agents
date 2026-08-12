@tool
extends RefCounted
class_name LocalAgentAgentServer


const LlamaServerManager: GDScript = preload("res://addons/local_agents/runtime/LlamaServerManager.gd")

# Every spelling of "generate through the managed llama-server process" accepted in an options
# dictionary's `backend` field. Anything else means in-process inference.
const SERVER_BACKENDS: Array = [
    "llama_server",
    "llama-server",
    "llama.cpp_server",
    "llama.cpp-http",
    "llama_cpp_http",
    "llama_http",
]

var _manager: LlamaServerManager = LlamaServerManager.new()
var _shutdown_on_exit: bool = true


## True when these options ask for the managed llama-server rather than in-process inference.
static func is_server_backend(opts: Dictionary) -> bool:
    var backend: String = String(opts.get("backend", "")).to_lower().strip_edges()
    return backend in SERVER_BACKENDS


func ensure_running(opts: Dictionary, model_path: String, runtime_dir: String) -> Dictionary:
    if not is_server_backend(opts):
        return {}
    var autostart: bool = bool(opts.get("server_autostart", true))
    _shutdown_on_exit = bool(opts.get("server_shutdown_on_exit", true))
    if not autostart:
        return {}
    var lifecycle: Dictionary = _manager.ensure_running(opts, model_path, runtime_dir)
    if not bool(lifecycle.get("ok", false)):
        return {
            "ok": false,
            "provider": "llama_server",
            "error": String(lifecycle.get("error", "llama_server_unavailable")),
            "lifecycle": lifecycle,
        }
    return {}


func stop_managed() -> Dictionary:
    return _manager.stop_managed()


## Teardown for _exit_tree: stop the managed server unless the last request opted out of it.
func stop_on_exit() -> void:
    if _shutdown_on_exit:
        _manager.stop_managed()
