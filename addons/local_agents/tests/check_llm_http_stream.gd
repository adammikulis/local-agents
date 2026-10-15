extends RefCounted

var _runtime: Object
var _thread: Thread
var _done: bool = false
var _result: Dictionary = {}
var _updates: PackedStringArray = PackedStringArray()
var _updated_before_done: bool = false
var _port: int

func run_test(tree: SceneTree) -> bool:
    _port = int(OS.get_environment("LA_STREAM_TEST_PORT"))
    _runtime = Engine.get_singleton("AgentRuntime")
    if _runtime == null or _port == 0:
        printerr("HTTP_STREAM_UNAVAILABLE")
        return false
    for case: String in ["valid", "incomplete", "invalid_tool", "http_error"]:
        _done = false
        _result = {}
        _updates = PackedStringArray()
        _updated_before_done = false
        _thread = Thread.new()
        _thread.start(Callable(self, "_worker").bind(case))
        var metadata_responsive: bool = true
        while not _done:
            await tree.process_frame
            var started: int = Time.get_ticks_usec()
            _runtime.is_model_loaded()
            _runtime.get_runtime_health()
            _runtime.get_default_model_path()
            metadata_responsive = metadata_responsive and Time.get_ticks_usec() - started < 100000
        _thread.wait_to_finish()
        var valid: bool = false
        if case == "valid":
            var tools: Array = _result.get("tool_calls", [])
            valid = bool(_result.get("ok", false)) and String(_result.get("text", "")) == "Hello 🌍"
            valid = valid and metadata_responsive and _updated_before_done and _updates.size() >= 2 and _updates[-1] == "Hello 🌍"
            valid = valid and tools.size() == 1 and String(tools[0]["function"]["arguments"]) == '{"x":1}'
            valid = valid and int(_result.get("usage", {}).get("completion_tokens", 0)) == 2
        else:
            valid = not bool(_result.get("ok", true))
            if case == "incomplete":
                valid = valid and _result.get("detail", "") == "stream_incomplete"
            elif case == "invalid_tool":
                valid = valid and _result.get("detail", "") == "invalid_stream_event"
            else:
                valid = valid and _result.get("error", "") == "http_status_error" and _updates.is_empty()
        if not valid:
            printerr("HTTP_STREAM_FAILED: " + case + " " + JSON.stringify(_result))
            return false
    print("check_llm_http_stream: OK")
    return true

func _worker(case: String) -> void:
    var result: Dictionary = _runtime.generate({
        "prompt": "Hello",
        "history": [{"role": "user", "content": "Hello"}],
        "options": {"backend": "llama_server", "server_base_url": "http://127.0.0.1:%d" % _port, "model": case},
        "stream_callback": Callable(self, "_on_progress"),
    })
    Callable(self, "_on_complete").call_deferred(result)

func _on_progress(text: String) -> void:
    _updated_before_done = _updated_before_done or not _done
    _updates.append(text)

func _on_complete(result: Dictionary) -> void:
    _result = result
    _done = true
