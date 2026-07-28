@tool
extends RefCounted
class_name LocalAgentAgentJobs

## The worker thread behind LocalAgent.think_async: one in-flight job per agent, started from the main
## thread with everything it needs already snapshotted into plain values, and handing its result back
## on the main thread.
##
## The worker calls the signal-FREE AgentRuntime.generate() instead of AgentNode.think(), because
## think() emits message_emitted on the node and Godot forbids emitting a node's signals from a worker
## thread. generate() is the same inference underneath (both backends, mutex-guarded) but pure
## data-in/data-out, so it is safe off-thread.
##
## Nothing in this file reads the scene. start() is handed a job Dictionary the agent built on the main
## thread, plus a `completion` Callable that is invoked deferred - so it lands on the main thread, which
## is where the agent's signals and history live.
##
## (Explicit types only - project rule: no ':=' inferred typing.)

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


## Block until the in-flight job (if any) is done. Called from _exit_tree: a think may still be
## running when the scene closes.
func join() -> void:
    if _thread != null:
        _thread.wait_to_finish()
        _thread = null


## Run `job` on a worker thread. `job` holds the pre-snapshotted request, options, resolved server
## model path, runtime directory and per-agent model path; `completion` is called (deferred, so on the
## main thread) with the result Dictionary, whether it succeeded or not.
func start(job: Dictionary, server: AgentServer, completion: Callable) -> void:
    _thread = Thread.new()
    _thread.start(Callable(self, "_worker").bind(job, server, completion))


# Worker-thread body: ensure the llama-server if needed (HTTP/process only - no scene touch), then run
# the signal-free generate(). Every input is a pre-snapshotted plain value.
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
