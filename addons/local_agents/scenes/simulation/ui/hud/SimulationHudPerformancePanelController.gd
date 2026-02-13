extends RefCounted

const SimulationTimingGraphScript = preload("res://addons/local_agents/scenes/simulation/ui/SimulationTimingGraph.gd")

var _hud: CanvasLayer
var _perf_label: Label
var _sim_timing_label: Label
var _timing_graph: Control
var _custom_inspector_rows_root: VBoxContainer
var _custom_inspector_rows: Dictionary = {}

func configure(hud: CanvasLayer, show_performance_overlay: bool) -> void:
	_hud = hud
	_perf_label = _hud.get_node_or_null("%PerfLabel") as Label
	_sim_timing_label = _hud.get_node_or_null("%SimTimingLabel") as Label
	if _perf_label != null:
		_perf_label.visible = show_performance_overlay
	_ensure_timing_graph()

func has_performance_label() -> bool:
	return _perf_label != null

func set_performance_text(text: String) -> void:
	if _perf_label == null:
		return
	_perf_label.text = text

func set_sim_timing_text(text: String) -> void:
	if _sim_timing_label == null:
		return
	_sim_timing_label.text = text

func set_sim_timing_profile(profile: Dictionary) -> void:
	if _timing_graph == null:
		_ensure_timing_graph()
	if _timing_graph != null and _timing_graph.has_method("push_profile"):
		_timing_graph.call("push_profile", profile)

func set_series_visible(series_key: String, visible: bool) -> void:
	if _timing_graph == null:
		return
	if _timing_graph.has_method("set_series_visible"):
		_timing_graph.call("set_series_visible", series_key, visible)

func set_performance_metrics(_metrics: Dictionary) -> void:
	pass

func set_frame_inspector_item(item_id: String, text: String, color: Color = Color(1.0, 1.0, 1.0, 1.0)) -> void:
	var key := item_id.strip_edges()
	if key == "":
		return
	if _custom_inspector_rows_root == null:
		_ensure_timing_graph()
	if _custom_inspector_rows_root == null:
		return
	var label: Label = _custom_inspector_rows.get(key, null)
	if label == null or not is_instance_valid(label):
		label = Label.new()
		label.name = "InspectorRow_%s" % key
		_custom_inspector_rows_root.add_child(label)
		_custom_inspector_rows[key] = label
	label.text = text
	label.modulate = color

func remove_frame_inspector_item(item_id: String) -> void:
	var key := item_id.strip_edges()
	if key == "":
		return
	var label: Label = _custom_inspector_rows.get(key, null)
	if label != null and is_instance_valid(label):
		label.queue_free()
	_custom_inspector_rows.erase(key)

func clear_frame_inspector_items() -> void:
	for key_variant in _custom_inspector_rows.keys():
		var label: Label = _custom_inspector_rows.get(key_variant, null)
		if label != null and is_instance_valid(label):
			label.queue_free()
	_custom_inspector_rows.clear()

func _ensure_timing_graph() -> void:
	if _timing_graph != null and is_instance_valid(_timing_graph):
		return
	if _sim_timing_label == null:
		return
	var parent := _sim_timing_label.get_parent()
	if parent == null:
		return
	_timing_graph = SimulationTimingGraphScript.new()
	_timing_graph.name = "SimTimingGraph"
	_timing_graph.custom_minimum_size = Vector2(0.0, 124.0)
	parent.add_child(_timing_graph)
	var insert_index := _sim_timing_label.get_index() + 1
	parent.move_child(_timing_graph, insert_index)
	_ensure_custom_inspector_rows_root(parent, insert_index + 1)

func _ensure_custom_inspector_rows_root(parent: Node, insert_index: int) -> void:
	if _custom_inspector_rows_root != null and is_instance_valid(_custom_inspector_rows_root):
		return
	if not (parent is VBoxContainer):
		return
	_custom_inspector_rows_root = VBoxContainer.new()
	_custom_inspector_rows_root.name = "CustomInspectorRows"
	_custom_inspector_rows_root.add_theme_constant_override("separation", 2)
	parent.add_child(_custom_inspector_rows_root)
	parent.move_child(_custom_inspector_rows_root, insert_index)
