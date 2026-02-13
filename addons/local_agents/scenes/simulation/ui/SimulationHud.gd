extends CanvasLayer

signal play_pressed
signal pause_pressed
signal rewind_pressed
signal fast_forward_pressed
signal fork_pressed
signal inspector_npc_changed(npc_id)
signal overlays_changed(paths, resources, conflicts, smell, wind, temperature)

@export var show_performance_overlay: bool = true
@export var performance_server_path: NodePath = NodePath("../PerformanceTelemetryServer")

@onready var perf_label: Label = get_node_or_null("%PerfLabel")
@onready var status_label: Label = %StatusLabel
@onready var details_label: Label = get_node_or_null("%DetailsLabel")
@onready var inspector_npc_edit: LineEdit = get_node_or_null("%InspectorNpcEdit")
@onready var path_toggle: CheckBox = get_node_or_null("%PathToggle")
@onready var resource_toggle: CheckBox = get_node_or_null("%ResourceToggle")
@onready var conflict_toggle: CheckBox = get_node_or_null("%ConflictToggle")
@onready var smell_toggle: CheckBox = get_node_or_null("%SmellToggle")
@onready var wind_toggle: CheckBox = get_node_or_null("%WindToggle")
@onready var temperature_toggle: CheckBox = get_node_or_null("%TemperatureToggle")

var _performance_server: Node

func _ready() -> void:
	if perf_label == null:
		return
	perf_label.visible = show_performance_overlay
	_bind_performance_server()

func set_status_text(text: String) -> void:
	status_label.text = text

func set_details_text(text: String) -> void:
	if details_label == null:
		return
	details_label.text = text

func _on_play_button_pressed() -> void:
	emit_signal("play_pressed")

func _on_pause_button_pressed() -> void:
	emit_signal("pause_pressed")

func _on_rewind_button_pressed() -> void:
	emit_signal("rewind_pressed")

func _on_fast_forward_button_pressed() -> void:
	emit_signal("fast_forward_pressed")

func _on_fork_button_pressed() -> void:
	emit_signal("fork_pressed")

func set_inspector_npc(npc_id: String) -> void:
	if inspector_npc_edit == null:
		return
	if inspector_npc_edit.text == npc_id:
		return
	inspector_npc_edit.text = npc_id

func _on_inspector_npc_edit_text_submitted(new_text: String) -> void:
	emit_signal("inspector_npc_changed", String(new_text).strip_edges())

func _on_inspector_apply_button_pressed() -> void:
	if inspector_npc_edit == null:
		return
	emit_signal("inspector_npc_changed", String(inspector_npc_edit.text).strip_edges())

func _on_overlay_toggled(_pressed: bool) -> void:
	emit_signal(
		"overlays_changed",
		path_toggle != null and path_toggle.button_pressed,
		resource_toggle != null and resource_toggle.button_pressed,
		conflict_toggle != null and conflict_toggle.button_pressed,
		smell_toggle != null and smell_toggle.button_pressed,
		wind_toggle != null and wind_toggle.button_pressed,
		temperature_toggle != null and temperature_toggle.button_pressed
	)

func _on_performance_metrics_updated(metrics: Dictionary) -> void:
	if not show_performance_overlay or perf_label == null:
		return
	var fps: int = int(metrics.get("fps", 0))
	var frame_ms: float = 0.0
	if fps > 0:
		frame_ms = 1000.0 / float(fps)
	var memory_static: float = float(metrics.get("memory_static_bytes", 0.0))
	var object_count: int = int(metrics.get("object_count", 0))
	var draw_calls: int = int(metrics.get("draw_calls", 0))
	var primitives: int = int(metrics.get("primitives", 0))
	var vram_bytes: float = float(metrics.get("memory_vram_bytes", 0.0))
	perf_label.text = "FPS %d (%.1f ms) | RAM %s | VRAM %s | Obj %d | Prim %d | Draw %d" % [
		fps,
		frame_ms,
		_format_mib(memory_static),
		_format_mib(vram_bytes),
		object_count,
		primitives,
		draw_calls
	]

func _bind_performance_server() -> void:
	var server: Node = null
	if performance_server_path != NodePath():
		server = get_node_or_null(performance_server_path)
	if server == null:
		var servers = get_tree().get_nodes_in_group("performance_telemetry_server")
		if not servers.is_empty() and servers[0] is Node:
			server = servers[0] as Node
	_performance_server = server
	if _performance_server == null:
		perf_label.text = "Perf server missing"
		return
	if _performance_server.has_signal("metrics_updated"):
		_performance_server.connect("metrics_updated", Callable(self, "_on_performance_metrics_updated"))
	if _performance_server.has_method("force_emit"):
		_performance_server.call_deferred("force_emit")

func _format_mib(bytes_value: float) -> String:
	var mib: float = bytes_value / (1024.0 * 1024.0)
	return "%.1f MiB" % mib
