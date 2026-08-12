@tool
extends RefCounted
class_name LocalAgentAgentJobs


const AgentStatus: GDScript = preload("res://addons/local_agents/runtime/AgentStatus.gd")
const AgentServer: GDScript = preload("res://addons/local_agents/agents/AgentServer.gd")

var _thread: Thread = null


## True while a job is running. think_async rejects a second request rather than queueing it - the
## caller (a creature's slow brain, the streamer's budget) decides what to do when refused.
func is_busy() -> bool:
    return _thread != null and _thread.is_alive()


## Join a thread that has already finished, so the next start() gets a fresh one. Cheap no-op while a
## job is still running.
func reap() -> void:
    if _thread != null and not _thread.is_alive():
        _thread.wait_to_finish()
        _thread = null


func join() -> void:
    if _thread != null:
        _thread.wait_to_finish()
        _thread = null


func start(job: Dictionary, server: AgentServer, completion: Callable) -> void:
    _thread = Thread.new()
    _thread.start(Callable(self, "_worker").bind(job, server, completion))


func _worker(job: Dictionary, server: AgentServer, completion: Callable) -> void:
    var opts: Dictionary = job.get("opts", {})
    var server_err: Dictionary = server.ensure_running(opts, String(job.get("server_model_path", "")), String(job.get("runtime_dir", "")))
    if not server_err.is_empty():
        completion.call_deferred(server_err)
        return
    var runtime: Object = job.get("runtime", null)
    if runtime == null:
        completion.call_deferred({"ok": false, "error": "runtime_unavailable"})
        return
    # Same per-agent model swap as the sync path, done HERE so the load cost stays off the frame.
    if not AgentServer.is_server_backend(opts):
        AgentStatus.load_model(String(job.get("agent_model_path", "")), opts)
    var result: Dictionary = runtime.generate(job.get("request", {}))
    completion.call_deferred(result)
