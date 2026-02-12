@tool
extends RefCounted

const InferenceParams := preload("res://addons/local_agents/configuration/parameters/InferenceParams.gd")

func run_test(_tree: SceneTree) -> bool:
    var cfg := InferenceParams.new()
    cfg.backend = "llama_server"
    cfg.output_json = true
    cfg.server_base_url = "http://127.0.0.1:1"
    cfg.server_model = "local-test-model"
    cfg.server_timeout_sec = 2
    cfg.server_slot = 0
    cfg.server_cache_prompt = true
    cfg.server_extra_body = {"n_predict": 8}

    var opts := cfg.to_options()
    var ok := true
    ok = ok and String(opts.get("backend", "")) == "llama_server"
    ok = ok and String(opts.get("server_base_url", "")) == "http://127.0.0.1:1"
    ok = ok and bool(opts.get("output_json", false))
    ok = ok and int(opts.get("id_slot", -1)) == 0
    ok = ok and bool(opts.get("cache_prompt", false))
    ok = ok and typeof(opts.get("server_extra_body", null)) == TYPE_DICTIONARY

    if Engine.has_singleton("AgentRuntime"):
        var runtime := Engine.get_singleton("AgentRuntime")
        if runtime != null:
            var response: Dictionary = runtime.call("generate", {
                "prompt": "Ping",
                "options": opts,
            })
            ok = ok and String(response.get("provider", "")) == "llama_server"
            ok = ok and not bool(response.get("ok", false))
            ok = ok and String(response.get("error", "")) in [
                "http_request_failed",
                "http_status_error",
                "missing_server_base_url",
                "missing_messages",
            ]

    if ok:
        print("Local Agents llama server provider test passed")
    else:
        push_error("Llama server provider test failed")
    return ok
