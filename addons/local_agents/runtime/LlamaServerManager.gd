@tool
extends RefCounted
class_name LocalAgentsLlamaServerManager

const RuntimePaths := preload("res://addons/local_agents/runtime/RuntimePaths.gd")

var _managed_pid: int = -1
var _managed_base_url: String = ""
var _managed_model_path: String = ""
var _managed_runtime_dir: String = ""
var _last_startup_report: Dictionary = {}
# Negative cache: once an ensure attempt fails with no managed server up, remember it so the next calls
# short-circuit instead of each re-paying the probe/spawn. This is what lets a creature/demo with no model
# ready degrade to its fast policy INSTANTLY on every subsequent frame instead of stalling repeatedly.
# Cleared whenever a server is successfully found/started. Re-probed after a cooldown so a server that comes
# up later is still picked up.
var _unavailable_until_ms: int = -1
const UNAVAILABLE_COOLDOWN_MS: int = 3000
# Quick single-shot connect budget for the "is a server ALREADY running?" probe — long enough for a local
# server that is up to answer, short enough that a miss returns fast instead of the old 1200 ms spin.
const QUICK_PROBE_CONNECT_MS: int = 200

func ensure_running(options: Dictionary, model_path: String, runtime_dir: String = "") -> Dictionary:
    var base_url := _normalized_base_url(options)
    # Fast path: a managed server we already started is up — skip all probing (no HTTP, no spin).
    if _managed_pid > 0 and _managed_base_url == base_url:
        return {"ok": true, "managed": true, "base_url": base_url}
    # Negative cache: a recent attempt failed and nothing is managed — short-circuit so the caller (often a
    # per-frame creature/demo cognition tick) drops to its fast policy immediately instead of re-stalling.
    if _managed_pid <= 0 and _unavailable_until_ms > 0 and Time.get_ticks_msec() < _unavailable_until_ms:
        return {"ok": false, "error": "llm_unavailable_cached", "base_url": base_url}
    var host_port := _parse_host_port(base_url)
    var report := _build_startup_report(options, model_path, runtime_dir, base_url)
    if not bool(host_port.get("ok", false)):
        report["ok"] = false
        report["error"] = "invalid_server_base_url"
        _last_startup_report = report
        return {
            "ok": false,
            "error": "invalid_server_base_url",
            "base_url": base_url,
        }

    # "Is a server ALREADY running?" — a SINGLE quick probe, not the old 1200 ms retry spin. If one is up it
    # answers in a few ms; if not, this returns fast so we fall through to spawn (or to the fast policy) without
    # blocking the caller's frame.
    if _probe_server_ready(String(host_port.get("host", "127.0.0.1")), int(host_port.get("port", 8080))):
        _unavailable_until_ms = -1
        report["ok"] = true
        report["already_running"] = true
        report["managed"] = false
        _last_startup_report = report
        return {
            "ok": true,
            "managed": false,
            "base_url": base_url,
        }

    var resolved_model_path := _normalize_path(model_path)
    if resolved_model_path == "" or not FileAccess.file_exists(resolved_model_path):
        # No model on disk — the common "nothing is ready" case (#20). Cache it so a per-frame cognition tick
        # stops re-checking the filesystem every call and drops to fast policy instantly.
        _unavailable_until_ms = Time.get_ticks_msec() + UNAVAILABLE_COOLDOWN_MS
        report["ok"] = false
        report["error"] = "server_model_missing"
        _last_startup_report = report
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
        report["ok"] = false
        report["error"] = "llama_server_binary_missing"
        _last_startup_report = report
        return {
            "ok": false,
            "error": "llama_server_binary_missing",
            "runtime_directory": resolved_runtime_dir,
        }
    report["binary"] = server_binary
    report["version"] = _server_version(server_binary)

    if _managed_pid > 0 and OS.is_process_running(_managed_pid):
        var same_server := _managed_base_url == base_url and _managed_model_path == resolved_model_path
        if same_server:
            if _is_server_ready(String(host_port.get("host", "127.0.0.1")), int(host_port.get("port", 8080)), int(options.get("server_ready_timeout_ms", 1200))):
                report["ok"] = true
                report["already_running"] = true
                report["managed"] = true
                report["pid"] = _managed_pid
                _last_startup_report = report
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
        "--jinja",
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
        report["ok"] = false
        report["error"] = "llama_server_spawn_failed"
        report["binary"] = server_binary
        _last_startup_report = report
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
        _unavailable_until_ms = Time.get_ticks_msec() + UNAVAILABLE_COOLDOWN_MS   # don't re-spawn every call
        report["ok"] = false
        report["error"] = "llama_server_start_timeout"
        report["pid"] = pid
        report["binary"] = server_binary
        _last_startup_report = report
        return {
            "ok": false,
            "error": "llama_server_start_timeout",
            "base_url": base_url,
            "pid": pid,
        }

    _unavailable_until_ms = -1                       # a server is up now — clear the negative cache
    report["ok"] = true
    report["managed"] = true
    report["pid"] = pid
    report["binary"] = server_binary
    report["base_url"] = base_url
    report["runtime_directory"] = resolved_runtime_dir
    report["model_path"] = resolved_model_path
    _last_startup_report = report
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
        "startup_report": _last_startup_report.duplicate(true),
    }

func startup_report() -> Dictionary:
    return _last_startup_report.duplicate(true)

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

# Single-shot readiness probe with a SHORT connect budget: one /health + /v1/models attempt, no retry spin.
# Used for the "is a server already running?" question so a miss returns in ~QUICK_PROBE_CONNECT_MS instead of
# the ~1200 ms the retry loop used to cost — the difference between a drop-in agent stalling at startup and
# degrading to fast policy instantly.
func _probe_server_ready(host: String, port: int) -> bool:
    if _http_get_ready(host, port, "/health", QUICK_PROBE_CONNECT_MS):
        return true
    return _http_get_ready(host, port, "/v1/models", QUICK_PROBE_CONNECT_MS)

func _http_get_ready(host: String, port: int, path: String, connect_budget_ms: int = 1000) -> bool:
    var client := HTTPClient.new()
    var connect_err := client.connect_to_host(host, port)
    if connect_err != OK:
        return false

    var connect_deadline: int = Time.get_ticks_msec() + maxi(50, connect_budget_ms)
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

func _build_startup_report(options: Dictionary, model_path: String, runtime_dir: String, base_url: String) -> Dictionary:
    return {
        "timestamp_unix": Time.get_unix_time_from_system(),
        "base_url": base_url,
        "model_path_requested": _normalize_path(model_path),
        "runtime_directory_requested": RuntimePaths.normalize_path(runtime_dir),
        "flags": {
            "context_size": int(options.get("context_size", 0)),
            "batch_size": int(options.get("batch_size", 0)),
            "threads": int(options.get("threads", options.get("n_threads", 0))),
            "n_gpu_layers": int(options.get("n_gpu_layers", 0)),
            "server_slots": int(options.get("server_slots", 1)),
            "server_embeddings": bool(options.get("server_embeddings", false)),
            "server_pooling": String(options.get("server_pooling", "")).strip_edges(),
        },
        "capabilities": {
            "parallel_requests": int(options.get("server_slots", 1)) > 1,
            "batching": int(options.get("batch_size", 0)) > 0,
            "embeddings": bool(options.get("server_embeddings", false)),
        },
    }

func _server_version(binary_path: String) -> String:
    if binary_path.strip_edges() == "":
        return ""
    var output := []
    var err := OS.execute(binary_path, ["--version"], output, true)
    if err != OK:
        return ""
    if output.is_empty():
        return ""
    return String(output[0]).strip_edges()
