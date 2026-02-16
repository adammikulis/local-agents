extends RefCounted

var _root: Node
var _show_performance_overlay: bool = true
var _performance_server_path: NodePath = NodePath()
var _performance_server: Node
var _set_perf_text: Callable
var _set_perf_metrics: Callable
var _runtime_diagnostics_provider: Callable

func configure(root: Node, show_performance_overlay: bool, performance_server_path: NodePath, set_perf_text: Callable, set_perf_metrics: Callable = Callable(), runtime_diagnostics_provider: Callable = Callable()) -> void:
	_root = root
	_show_performance_overlay = show_performance_overlay
	_performance_server_path = performance_server_path
	_set_perf_text = set_perf_text
	_set_perf_metrics = set_perf_metrics
	_runtime_diagnostics_provider = runtime_diagnostics_provider

func bind_performance_server() -> void:
	if _root == null:
		return
	var server: Node = null
	if _performance_server_path != NodePath():
		server = _root.get_node_or_null(_performance_server_path)
	if server == null:
		var servers = _root.get_tree().get_nodes_in_group("performance_telemetry_server")
		if not servers.is_empty() and servers[0] is Node:
			server = servers[0] as Node
	_performance_server = server
	if _performance_server == null:
		_set_performance_text("Perf server missing")
		return
	if _performance_server.has_signal("metrics_updated"):
		var callback := Callable(self, "_on_performance_metrics_updated")
		if not _performance_server.is_connected("metrics_updated", callback):
			_performance_server.connect("metrics_updated", callback)
	if _performance_server.has_method("force_emit"):
		_performance_server.call_deferred("force_emit")

func _on_performance_metrics_updated(metrics: Dictionary) -> void:
	if not _show_performance_overlay:
		return
	if _set_perf_metrics.is_valid():
		_set_perf_metrics.call(metrics)
	_set_performance_text(_build_performance_text(metrics))

func _build_performance_text(metrics: Dictionary) -> String:
	var fps: int = int(metrics.get("fps", 0))
	var frame_ms: float = 0.0
	if fps > 0:
		frame_ms = 1000.0 / float(fps)
	var memory_static: float = float(metrics.get("memory_static_bytes", 0.0))
	var object_count: int = int(metrics.get("object_count", 0))
	var draw_calls: int = int(metrics.get("draw_calls", 0))
	var primitives: int = int(metrics.get("primitives", 0))
	var vram_bytes: float = float(metrics.get("memory_vram_bytes", 0.0))
	var backend_flags := ""
	var runtime_backends: Dictionary = metrics.get("runtime_backends", {})
	if runtime_backends is Dictionary and not runtime_backends.is_empty():
		var dispatch_status = String(runtime_backends.get("dispatch_contract_status", "unknown")).strip_edges()
		if dispatch_status == "":
			dispatch_status = "unknown"
		var material_model_variant = runtime_backends.get("material_model", {})
		var material_model: Dictionary = material_model_variant if material_model_variant is Dictionary else {}
		var emitter_model_variant = runtime_backends.get("emitter_model", {})
		var emitter_model: Dictionary = emitter_model_variant if emitter_model_variant is Dictionary else {}
		var material_key = String(material_model.get("profile_key", "none")).strip_edges()
		if material_key == "":
			material_key = "none"
		var emitter_key = String(emitter_model.get("profile_key", "none")).strip_edges()
		if emitter_key == "":
			emitter_key = "none"
		backend_flags = " | X[%s|M:%s|E:%s]" % [dispatch_status, material_key, emitter_key]
	var destruction_diagnostics := _destruction_diagnostics(metrics)
	if not destruction_diagnostics.is_empty():
		var last_drop_reason = String(destruction_diagnostics.get("last_drop_reason", "-")).strip_edges()
		if last_drop_reason == "":
			last_drop_reason = "-"
		var fps_mode_active := bool(destruction_diagnostics.get("fps_mode_active", false))
		backend_flags += " | D[HQ:%d CD:%d PP:%d OA:%d CT:%d LR:%s FM:%s FA:%d FS:%d DF:%d MF:%d]" % [
			int(destruction_diagnostics.get("hits_queued", 0)),
			int(destruction_diagnostics.get("contacts_dispatched", 0)),
			int(destruction_diagnostics.get("plans_planned", 0)),
			int(destruction_diagnostics.get("ops_applied", 0)),
			int(destruction_diagnostics.get("changed_tiles", 0)),
			last_drop_reason,
			"1" if fps_mode_active else "0",
			int(destruction_diagnostics.get("fire_attempts", 0)),
			int(destruction_diagnostics.get("fire_successes", 0)),
			int(destruction_diagnostics.get("dispatch_attempts_after_fire", 0)),
			int(destruction_diagnostics.get("first_mutation_frames_since_fire", -1)),
		]
	return "FPS %d (%.1f ms) | RAM %s | VRAM %s | Obj %d | Prim %d | Draw %d%s" % [
		fps,
		frame_ms,
		_format_mib(memory_static),
		_format_mib(vram_bytes),
		object_count,
		primitives,
		draw_calls,
		backend_flags,
	]

func _set_performance_text(text: String) -> void:
	if _set_perf_text.is_valid():
		_set_perf_text.call(text)

func _format_mib(bytes_value: float) -> String:
	var mib: float = bytes_value / (1024.0 * 1024.0)
	return "%.1f MiB" % mib

func _destruction_diagnostics(metrics: Dictionary) -> Dictionary:
	var diagnostics: Dictionary = {}
	var runtime_backends_variant = metrics.get("runtime_backends", {})
	if runtime_backends_variant is Dictionary:
		var runtime_backends = runtime_backends_variant as Dictionary
		var backend_diag_variant = runtime_backends.get("destruction_pipeline", {})
		if backend_diag_variant is Dictionary:
			diagnostics = (backend_diag_variant as Dictionary).duplicate(true)
	if diagnostics.is_empty() and _runtime_diagnostics_provider.is_valid():
		var runtime_diag_variant = _runtime_diagnostics_provider.call()
		if runtime_diag_variant is Dictionary:
			diagnostics = (runtime_diag_variant as Dictionary).duplicate(true)
	return diagnostics
