extends RefCounted
class_name LocalAgentLlmClient


var _agent: Node = null                 # a LocalAgent (agents/Agent.gd)
var _defaults: Dictionary = {}          # standing opts: backend / server_base_url / server_model_path / sampling
var _busy: bool = false
var _on_done: Callable = Callable()
var _connected: bool = false


func _init(agent: Node, defaults: Dictionary = {}) -> void:
	_agent = agent
	_defaults = defaults.duplicate(true)


## Is there a live agent to talk to? A true answer does not imply a model or a server is up. That
## surfaces as an `ok:false` result from the request, and callers treat a false request() the same
## as an unavailable model.
func is_available() -> bool:
	return _agent != null and is_instance_valid(_agent)


func is_busy() -> bool:
	return _busy


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
