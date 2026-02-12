@tool
extends RefCounted
class_name LocalAgentsLlamaServerManager

const RuntimePaths := preload("res://addons/local_agents/runtime/RuntimePaths.gd")

var _managed_pid: int = -1
var _managed_base_url: String = ""
var _managed_model_path: String = ""
var _managed_runtime_dir: String = ""

func ensure_running(options: Dictionary, model_path: String, runtime_dir: String = "") -> Dictionary:
    var base_url := _normalized_base_url(options)
    var host_port := _parse_host_port(base_url)
    if not bool(host_port.get("ok", false)):
        return {
            "ok": false,
            "error": "invalid_server_base_url",
            "base_url": base_url,
        }

    if _is_server_ready(String(host_port.get("host", "127.0.0.1")), int(host_port.get("port", 8080)), int(options.get("server_ready_timeout_ms", 1200))):
        return {
            "ok": true,
            "managed": false,
            "base_url": base_url,
        }

    var resolved_model_path := _normalize_path(model_path)
    if resolved_model_path == "" or not FileAccess.file_exists(resolved_model_path):
        return {
            "ok": false,
            "error": "server_model_missing",
            "model_path": model_path,
        }

    var resolved_runtime_dir := RuntimePaths.normalize_path(runtime_dir)
    var server_binary := _normalize_path(String(options.get("server_binary_path", "")).strip_edges())
    if server_binary == "":
        server_binary = RuntimePaths.resolve_executable("llama-server", resolved_runtime_dir)
    if server_binary == "":
        server_binary = _runtime_health_binary("llama_server")
    if server_binary == "":
        server_binary = _bundled_binary_path("llama-server")
    if server_binary == "":
        return {
            "ok": false,
            "error": "llama_server_binary_missing",
            "runtime_directory": resolved_runtime_dir,
        }

    if _managed_pid > 0 and OS.is_process_running(_managed_pid):
        var same_server := _managed_base_url == base_url and _managed_model_path == resolved_model_path
        if same_server:
            if _is_server_ready(String(host_port.get("host", "127.0.0.1")), int(host_port.get("port", 8080)), int(options.get("server_ready_timeout_ms", 1200))):
                return {
                    "ok": true,
                    "managed": true,
                    "base_url": base_url,
                    "pid": _managed_pid,
                }
        _kill_managed()
    else:
        _clear_managed_state()

    var args := PackedStringArray([
        "--host", String(host_port.get("host", "127.0.0.1")),
        "--port", str(int(host_port.get("port", 8080))),
        "-m", resolved_model_path,
    ])

    var context_size := int(options.get("context_size", 0))
    if context_size > 0:
        args.append("-c")
        args.append(str(context_size))

    var batch_size := int(options.get("batch_size", 0))
    if batch_size > 0:
        args.append("-b")
        args.append(str(batch_size))

    var gpu_layers := int(options.get("n_gpu_layers", 0))
    if gpu_layers > 0:
        args.append("-ngl")
        args.append(str(gpu_layers))

    var slots := int(options.get("server_slots", 1))
    if slots > 1:
        args.append("-np")
        args.append(str(slots))

    if bool(options.get("server_embeddings", false)):
        args.append("--embeddings")
    var pooling_mode := String(options.get("server_pooling", "")).strip_edges()
    if pooling_mode != "":
        args.append("--pooling")
        args.append(pooling_mode)

    var pid := OS.create_process(server_binary, args, false)
    if pid <= 0:
        return {
            "ok": false,
            "error": "llama_server_spawn_failed",
            "binary": server_binary,
        }

    _managed_pid = pid
    _managed_base_url = base_url
    _managed_model_path = resolved_model_path
    _managed_runtime_dir = resolved_runtime_dir

    var startup_timeout_ms := int(options.get("server_start_timeout_ms", 30000))
    if not _is_server_ready(String(host_port.get("host", "127.0.0.1")), int(host_port.get("port", 8080)), startup_timeout_ms):
        _kill_managed()
        return {
            "ok": false,
            "error": "llama_server_start_timeout",
            "base_url": base_url,
            "pid": pid,
        }

    return {
        "ok": true,
        "managed": true,
        "base_url": base_url,
        "pid": pid,
    }

func stop_managed() -> Dictionary:
    if _managed_pid <= 0:
        return {"ok": true, "stopped": false}
    var pid := _managed_pid
    var err := OS.kill(pid)
    _clear_managed_state()
    return {
        "ok": err == OK,
        "stopped": err == OK,
        "pid": pid,
        "error_code": err,
    }

func status() -> Dictionary:
    return {
        "managed_pid": _managed_pid,
        "managed_running": _managed_pid > 0 and OS.is_process_running(_managed_pid),
        "base_url": _managed_base_url,
        "model_path": _managed_model_path,
        "runtime_directory": _managed_runtime_dir,
    }

func _kill_managed() -> void:
    if _managed_pid > 0:
        OS.kill(_managed_pid)
    _clear_managed_state()

func _clear_managed_state() -> void:
    _managed_pid = -1
    _managed_base_url = ""
    _managed_model_path = ""
    _managed_runtime_dir = ""

func _normalized_base_url(options: Dictionary) -> String:
    var base_url := String(options.get("server_base_url", options.get("base_url", "http://127.0.0.1:8080"))).strip_edges()
    if base_url == "":
        base_url = "http://127.0.0.1:8080"
    while base_url.ends_with("/"):
        base_url = base_url.substr(0, base_url.length() - 1)
    return base_url

func _parse_host_port(base_url: String) -> Dictionary:
    var without_scheme := base_url
    var scheme_sep := without_scheme.find("://")
    if scheme_sep != -1:
        without_scheme = without_scheme.substr(scheme_sep + 3)
    var slash_idx := without_scheme.find("/")
    if slash_idx != -1:
        without_scheme = without_scheme.substr(0, slash_idx)

    if without_scheme == "":
        return {"ok": false}

    var host := without_scheme
    var port := 8080
    var colon_idx := without_scheme.rfind(":")
    if colon_idx > -1 and colon_idx < without_scheme.length() - 1:
        host = without_scheme.substr(0, colon_idx)
        var parsed_port := int(without_scheme.substr(colon_idx + 1))
        if parsed_port > 0 and parsed_port <= 65535:
            port = parsed_port
    if host == "":
        host = "127.0.0.1"
    return {
        "ok": true,
        "host": host,
        "port": port,
    }

func _is_server_ready(host: String, port: int, timeout_ms: int) -> bool:
    var deadline: int = Time.get_ticks_msec() + maxi(100, timeout_ms)
    while Time.get_ticks_msec() < deadline:
        if _http_get_ready(host, port, "/health"):
            return true
        if _http_get_ready(host, port, "/v1/models"):
            return true
        OS.delay_msec(120)
    return false

func _http_get_ready(host: String, port: int, path: String) -> bool:
    var client := HTTPClient.new()
    var connect_err := client.connect_to_host(host, port)
    if connect_err != OK:
        return false

    var connect_deadline: int = Time.get_ticks_msec() + 1000
    while Time.get_ticks_msec() < connect_deadline:
        client.poll()
        var status := client.get_status()
        if status == HTTPClient.STATUS_CONNECTED:
            break
        if status == HTTPClient.STATUS_CANT_CONNECT or status == HTTPClient.STATUS_CONNECTION_ERROR:
            client.close()
            return false
        OS.delay_msec(10)

    if client.get_status() != HTTPClient.STATUS_CONNECTED:
        client.close()
        return false

    var req_err := client.request(HTTPClient.METHOD_GET, path, PackedStringArray(), "")
    if req_err != OK:
        client.close()
        return false

    var request_deadline: int = Time.get_ticks_msec() + 1200
    while Time.get_ticks_msec() < request_deadline:
        client.poll()
        var req_status := client.get_status()
        if req_status == HTTPClient.STATUS_BODY:
            var chunk = client.read_response_body_chunk()
            if chunk.size() == 0:
                continue
        elif req_status == HTTPClient.STATUS_CONNECTED:
            var code := client.get_response_code()
            client.close()
            return code >= 200 and code < 300
        elif req_status == HTTPClient.STATUS_DISCONNECTED:
            break
        OS.delay_msec(10)

    var code := client.get_response_code()
    client.close()
    return code >= 200 and code < 300

func _normalize_path(path: String) -> String:
    if path.begins_with("res://") or path.begins_with("user://"):
        return ProjectSettings.globalize_path(path)
    return path

func _runtime_health_binary(key: String) -> String:
    if not Engine.has_singleton("AgentRuntime"):
        return ""
    var runtime = Engine.get_singleton("AgentRuntime")
    if runtime == null or not runtime.has_method("get_runtime_health"):
        return ""
    var health: Dictionary = runtime.call("get_runtime_health")
    var binaries: Dictionary = health.get("binaries", {})
    var path := String(binaries.get(key, "")).strip_edges()
    return path

func _bundled_binary_path(name: String) -> String:
    var candidates := [
        "res://addons/local_agents/gdextensions/localagents/bin/%s" % name,
        "res://addons/local_agents/gdextensions/localagents/bin/%s.exe" % name,
    ]
    for candidate in candidates:
        var normalized := _normalize_path(candidate)
        if normalized != "" and FileAccess.file_exists(normalized):
            return normalized
    return ""
