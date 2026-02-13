extends RefCounted

var _root: Node
var _show_performance_overlay: bool = true
var _performance_server_path: NodePath = NodePath()
var _performance_server: Node
var _set_perf_text: Callable

func configure(root: Node, show_performance_overlay: bool, performance_server_path: NodePath, set_perf_text: Callable) -> void:
	_root = root
	_show_performance_overlay = show_performance_overlay
	_performance_server_path = performance_server_path
	_set_perf_text = set_perf_text

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
		backend_flags = " | C[%s%s%s%s]" % [
			"H" if bool(runtime_backends.get("hydrology_compute", false)) else "h",
			"W" if bool(runtime_backends.get("weather_compute", false)) else "w",
			"E" if bool(runtime_backends.get("erosion_compute", false)) else "e",
			"S" if bool(runtime_backends.get("solar_compute", false)) else "s",
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
