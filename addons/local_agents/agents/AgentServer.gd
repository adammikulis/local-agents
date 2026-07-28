@tool
extends RefCounted
class_name LocalAgentAgentServer

## The managed llama-server side of LocalAgent: deciding whether a request wants that backend at all,
## bringing the server process up before the request goes out, and tearing it down when the agent
## leaves the tree.
##
## Split out of Agent.gd so the node keeps the inference API and this file keeps the process
## lifecycle. Every method here is safe to call from the think_async WORKER thread as well as the main
## thread: it only touches HTTP/process state and plain values, never the scene.
##
## (Explicit types only - project rule: no ':=' inferred typing.)

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
# The `server_shutdown_on_exit` of the last request that reached this agent. Read by stop_on_exit()
# when the node leaves the tree, so an agent whose last request asked the server to outlive the scene
# does not kill it on the way out.
var _shutdown_on_exit: bool = true


## True when these options ask for the managed llama-server rather than in-process inference.
static func is_server_backend(opts: Dictionary) -> bool:
    var backend: String = String(opts.get("backend", "")).to_lower().strip_edges()
    return backend in SERVER_BACKENDS


## Bring the managed server up for a llama-server-backend request. Returns {} when nothing needed
## doing - wrong backend, autostart off, or already running - and otherwise an error dictionary shaped
## like a failed think() result, so a caller can return it straight through.
##
## Takes a pre-resolved model_path + runtime_dir rather than reading them itself, so the same call
## works from the main thread (sync think) and from the worker (think_async) without touching the node.
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


## Stop the server this agent started, whatever the last request asked for. Public because scenes and
## tests shut the process down explicitly (LocalAgent.stop_managed_llama_server).
func stop_managed() -> Dictionary:
    return _manager.stop_managed()


## Teardown for _exit_tree: stop the managed server unless the last request opted out of it.
func stop_on_exit() -> void:
    if _shutdown_on_exit:
        _manager.stop_managed()
