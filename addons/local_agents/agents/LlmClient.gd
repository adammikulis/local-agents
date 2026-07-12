extends RefCounted
class_name LocalAgentLlmClient

## The one seam that lets ANY consumer treat a LocalAgent as a plain async LLM endpoint. It wraps a
## single LocalAgent's think_async(): request() builds the native options (messages + optional tool
## specs + backend/server), fires one async think, and routes the single think_completed back to the
## caller's on_done. This is what collapses the three forked chat-completions clients into one path —
## a creature's slow brain and the streamer's commentator now run through the SAME LocalAgent.
##
## Single-in-flight per client: a second request while one is running is REJECTED (returns false), so
## the caller (the slow-brain scheduler's global budget, the streamer's pending-request gate) decides
## what to do — fall back to the heuristic teacher, skip the beat, etc. That keeps one shared server
## honest without a queue.
##
## (Explicit types only — project rule: no ':=' inferred typing.)

var _agent: Node = null                 # a LocalAgent (agents/Agent.gd)
var _defaults: Dictionary = {}          # standing opts: backend / server_base_url / server_model_path / sampling
var _busy: bool = false
var _on_done: Callable = Callable()
var _connected: bool = false


func _init(agent: Node, defaults: Dictionary = {}) -> void:
	_agent = agent
	_defaults = defaults.duplicate(true)


## Is there a live agent to talk to? (Does NOT imply a model/server is up — that surfaces as an
## `ok:false` result from the request; callers treat a false request() the same as an unavailable model.)
func is_available() -> bool:
	return _agent != null and is_instance_valid(_agent)


func is_busy() -> bool:
	return _busy


## Fire one async chat/tool request.
##   messages : OpenAI-style [{role,content}] array (the native path reads opts.messages directly).
##   tools    : function specs (may be empty); when present the model is forced to call exactly one
##              (tool_choice defaults to "required").
##   opts     : per-call overrides merged over the standing defaults (temperature, max_tokens, …).
##   on_done  : called on the MAIN thread with the native think result Dictionary
##              ({ok, text, tool_calls?, response?, …}).
## Returns false immediately if the agent is unavailable or a request is already in flight.
func request(messages: Array, tools: Array, opts: Dictionary, on_done: Callable) -> bool:
	if not is_available() or _busy:
		return false
	if not _connected:
		_agent.think_completed.connect(_on_think_completed)
		_connected = true
	var think_opts: Dictionary = _defaults.duplicate(true)
	for k in opts.keys():
		think_opts[k] = opts[k]
	think_opts["messages"] = messages
	if not tools.is_empty():
		think_opts["tools"] = tools
		if not think_opts.has("tool_choice"):
			think_opts["tool_choice"] = "required"
	_busy = true
	_on_done = on_done
	if not bool(_agent.think_async("", think_opts)):
		# The agent refused to start (unavailable, or a stray in-flight) — clear our latch and report.
		_busy = false
		_on_done = Callable()
		return false
	return true


func _on_think_completed(result: Dictionary) -> void:
	var cb: Callable = _on_done
	_on_done = Callable()
	_busy = false
	if cb.is_valid():
		cb.call(result)
