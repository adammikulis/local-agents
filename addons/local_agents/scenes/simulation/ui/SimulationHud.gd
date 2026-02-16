extends CanvasLayer

const SimulationHudPresenterScript = preload("res://addons/local_agents/scenes/simulation/ui/SimulationHudPresenter.gd")
const SimulationHudGraphicsPanelControllerScript = preload("res://addons/local_agents/scenes/simulation/ui/hud/SimulationHudGraphicsPanelController.gd")
const SimulationHudPerformancePanelControllerScript = preload("res://addons/local_agents/scenes/simulation/ui/hud/SimulationHudPerformancePanelController.gd")
const SimulationHudInspectorPanelControllerScript = preload("res://addons/local_agents/scenes/simulation/ui/hud/SimulationHudInspectorPanelController.gd")

signal play_pressed
signal pause_pressed
signal rewind_pressed
signal fast_forward_pressed
signal fork_pressed
signal inspector_npc_changed(npc_id)
signal overlays_changed(paths, resources, conflicts, smell, wind, temperature)
signal graphics_option_changed(option_id, value)

@export var show_performance_overlay: bool = true
@export var performance_server_path: NodePath = NodePath("../PerformanceTelemetryServer")

@onready var perf_label: Label = get_node_or_null("%PerfLabel")
@onready var status_label: Label = %StatusLabel
@onready var details_label: Label = get_node_or_null("%DetailsLabel")
@onready var mode_label: Label = get_node_or_null("%ModeLabel")

var _hud_presenter = SimulationHudPresenterScript.new()
var _graphics_panel_controller = SimulationHudGraphicsPanelControllerScript.new()
var _performance_panel_controller = SimulationHudPerformancePanelControllerScript.new()
var _inspector_panel_controller = SimulationHudInspectorPanelControllerScript.new()

func _ready() -> void:
	if perf_label == null:
		return
	_performance_panel_controller.configure(self, show_performance_overlay)
	_graphics_panel_controller.configure(
		self,
		Callable(self, "_emit_graphics_option_changed"),
		Callable(self, "_set_frame_graph_series_visible")
	)
	_inspector_panel_controller.configure(
		self,
		Callable(self, "_emit_inspector_npc_changed"),
		Callable(self, "_emit_overlays_changed")
	)
	_hud_presenter.configure(
		self,
		show_performance_overlay,
		performance_server_path,
		Callable(self, "set_performance_text"),
		Callable(self, "set_performance_metrics")
	)
	_hud_presenter.bind_performance_server()

func set_status_text(text: String) -> void:
	status_label.text = text

func set_mode_label(text: String) -> void:
	if mode_label == null:
		return
	mode_label.text = text

func set_input_mode_text(text: String) -> void:
	set_mode_label(text)

func set_details_text(text: String) -> void:
	if details_label == null:
		return
	details_label.text = text

func set_performance_text(text: String) -> void:
	_performance_panel_controller.set_performance_text(text)

func set_sim_timing_text(text: String) -> void:
	_performance_panel_controller.set_sim_timing_text(text)

func set_sim_timing_profile(profile: Dictionary) -> void:
	_performance_panel_controller.set_sim_timing_profile(profile)

func set_performance_metrics(metrics: Dictionary) -> void:
	_performance_panel_controller.set_performance_metrics(metrics)

func set_frame_inspector_item(item_id: String, text: String, color: Color = Color(1.0, 1.0, 1.0, 1.0)) -> void:
	_performance_panel_controller.set_frame_inspector_item(item_id, text, color)

func remove_frame_inspector_item(item_id: String) -> void:
	_performance_panel_controller.remove_frame_inspector_item(item_id)

func clear_frame_inspector_items() -> void:
	_performance_panel_controller.clear_frame_inspector_items()

func set_graphics_label(text: String) -> void:
	_graphics_panel_controller.set_graphics_label(text)

func set_graphics_state(state: Dictionary) -> void:
	_graphics_panel_controller.set_graphics_state(state)

func set_inspector_npc(npc_id: String) -> void:
	_inspector_panel_controller.set_inspector_npc(npc_id)

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

func _on_graphics_button_pressed() -> void:
	_graphics_panel_controller.on_graphics_button_pressed()

func _on_graphics_toggle(_pressed: bool) -> void:
	_graphics_panel_controller.on_graphics_toggle()

func _on_frame_graph_toggle_changed(_pressed: bool, option_id: String) -> void:
	_graphics_panel_controller.on_frame_graph_toggle_changed(option_id)

func _on_cloud_quality_selected(index: int) -> void:
	_graphics_panel_controller.on_cloud_quality_selected(index)

func _on_cloud_density_slider_changed(value: float) -> void:
	_graphics_panel_controller.on_cloud_density_slider_changed(value)

func _on_cloud_density_spin_changed(value: float) -> void:
	_graphics_panel_controller.on_cloud_density_spin_changed(value)

func _on_rain_visual_slider_changed(value: float) -> void:
	_graphics_panel_controller.on_rain_visual_slider_changed(value)

func _on_rain_visual_spin_changed(value: float) -> void:
	_graphics_panel_controller.on_rain_visual_spin_changed(value)

func _on_terrain_chunk_size_slider_changed(value: float) -> void:
	_graphics_panel_controller.on_terrain_chunk_size_changed(value)

func _on_terrain_chunk_size_spin_changed(value: float) -> void:
	_graphics_panel_controller.on_terrain_chunk_size_changed(value)

func _on_perf_sim_tick_rate_slider_changed(value: float) -> void:
	_graphics_panel_controller.on_perf_sim_tick_rate_changed(value)

func _on_perf_sim_tick_rate_spin_changed(value: float) -> void:
	_graphics_panel_controller.on_perf_sim_tick_rate_changed(value)

func _on_perf_climate_fast_interval_slider_changed(value: float) -> void:
	_graphics_panel_controller.on_perf_climate_fast_interval_changed(value)

func _on_perf_climate_fast_interval_spin_changed(value: float) -> void:
	_graphics_panel_controller.on_perf_climate_fast_interval_changed(value)

func _on_perf_climate_slow_interval_slider_changed(value: float) -> void:
	_graphics_panel_controller.on_perf_climate_slow_interval_changed(value)

func _on_perf_climate_slow_interval_spin_changed(value: float) -> void:
	_graphics_panel_controller.on_perf_climate_slow_interval_changed(value)

func _on_perf_society_fast_interval_slider_changed(value: float) -> void:
	_graphics_panel_controller.on_perf_society_fast_interval_changed(value)

func _on_perf_society_fast_interval_spin_changed(value: float) -> void:
	_graphics_panel_controller.on_perf_society_fast_interval_changed(value)

func _on_perf_society_slow_interval_slider_changed(value: float) -> void:
	_graphics_panel_controller.on_perf_society_slow_interval_changed(value)

func _on_perf_society_slow_interval_spin_changed(value: float) -> void:
	_graphics_panel_controller.on_perf_society_slow_interval_changed(value)

func _on_perf_texture_interval_slider_changed(value: float) -> void:
	_graphics_panel_controller.on_perf_texture_interval_changed(value)

func _on_perf_texture_interval_spin_changed(value: float) -> void:
	_graphics_panel_controller.on_perf_texture_interval_changed(value)

func _on_perf_texture_budget_slider_changed(value: float) -> void:
	_graphics_panel_controller.on_perf_texture_budget_changed(value)

func _on_perf_texture_budget_spin_changed(value: float) -> void:
	_graphics_panel_controller.on_perf_texture_budget_changed(value)

func _on_perf_ecology_step_slider_changed(value: float) -> void:
	_graphics_panel_controller.on_perf_ecology_step_changed(value)

func _on_perf_ecology_step_spin_changed(value: float) -> void:
	_graphics_panel_controller.on_perf_ecology_step_changed(value)

func _on_ecology_voxel_size_slider_changed(value: float) -> void:
	_graphics_panel_controller.on_ecology_voxel_size_changed(value)

func _on_ecology_voxel_size_spin_changed(value: float) -> void:
	_graphics_panel_controller.on_ecology_voxel_size_changed(value)

func _on_ecology_vertical_extent_slider_changed(value: float) -> void:
	_graphics_panel_controller.on_ecology_vertical_extent_changed(value)

func _on_ecology_vertical_extent_spin_changed(value: float) -> void:
	_graphics_panel_controller.on_ecology_vertical_extent_changed(value)

func _on_inspector_npc_edit_text_submitted(new_text: String) -> void:
	_inspector_panel_controller.on_inspector_npc_edit_text_submitted(new_text)

func _on_inspector_apply_button_pressed() -> void:
	_inspector_panel_controller.on_inspector_apply_button_pressed()

func _on_overlay_toggled(_pressed: bool) -> void:
	_inspector_panel_controller.on_overlay_toggled()

func _emit_graphics_option_changed(option_id: String, value) -> void:
	emit_signal("graphics_option_changed", option_id, value)

func _set_frame_graph_series_visible(series_key: String, visible: bool) -> void:
	_performance_panel_controller.set_series_visible(series_key, visible)

func _emit_inspector_npc_changed(npc_id: String) -> void:
	emit_signal("inspector_npc_changed", npc_id)

func _emit_overlays_changed(paths: bool, resources: bool, conflicts: bool, smell: bool, wind: bool, temperature: bool) -> void:
	emit_signal("overlays_changed", paths, resources, conflicts, smell, wind, temperature)
