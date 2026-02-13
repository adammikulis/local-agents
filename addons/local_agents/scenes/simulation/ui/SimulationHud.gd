extends CanvasLayer
const SimulationHudPresenterScript = preload("res://addons/local_agents/scenes/simulation/ui/SimulationHudPresenter.gd")

signal play_pressed
signal pause_pressed
signal rewind_pressed
signal fast_forward_pressed
signal fork_pressed
signal inspector_npc_changed(npc_id)
signal overlays_changed(paths, resources, conflicts, smell, wind, temperature)
signal graphics_option_changed(option_id, value)
signal performance_mode_requested

@export var show_performance_overlay: bool = true
@export var performance_server_path: NodePath = NodePath("../PerformanceTelemetryServer")

@onready var perf_label: Label = get_node_or_null("%PerfLabel")
@onready var sim_timing_label: Label = get_node_or_null("%SimTimingLabel")
@onready var status_label: Label = %StatusLabel
@onready var details_label: Label = get_node_or_null("%DetailsLabel")
@onready var inspector_npc_edit: LineEdit = get_node_or_null("%InspectorNpcEdit")
@onready var path_toggle: CheckBox = get_node_or_null("%PathToggle")
@onready var resource_toggle: CheckBox = get_node_or_null("%ResourceToggle")
@onready var conflict_toggle: CheckBox = get_node_or_null("%ConflictToggle")
@onready var smell_toggle: CheckBox = get_node_or_null("%SmellToggle")
@onready var wind_toggle: CheckBox = get_node_or_null("%WindToggle")
@onready var temperature_toggle: CheckBox = get_node_or_null("%TemperatureToggle")
@onready var graphics_button: Button = get_node_or_null("%GraphicsButton")
@onready var graphics_panel: PanelContainer = get_node_or_null("%GraphicsPanel")
@onready var water_shader_check: CheckBox = get_node_or_null("%WaterShaderCheck")
@onready var ocean_surface_check: CheckBox = get_node_or_null("%OceanSurfaceCheck")
@onready var river_overlays_check: CheckBox = get_node_or_null("%RiverOverlaysCheck")
@onready var rain_post_fx_check: CheckBox = get_node_or_null("%RainPostFxCheck")
@onready var clouds_check: CheckBox = get_node_or_null("%CloudsCheck")
@onready var shadows_check: CheckBox = get_node_or_null("%ShadowsCheck")
@onready var ssr_check: CheckBox = get_node_or_null("%SsrCheck")
@onready var ssao_check: CheckBox = get_node_or_null("%SsaoCheck")
@onready var ssil_check: CheckBox = get_node_or_null("%SsilCheck")
@onready var sdfgi_check: CheckBox = get_node_or_null("%SdfgiCheck")
@onready var glow_check: CheckBox = get_node_or_null("%GlowCheck")
@onready var fog_check: CheckBox = get_node_or_null("%FogCheck")
@onready var volumetric_fog_check: CheckBox = get_node_or_null("%VolumetricFogCheck")
@onready var cloud_quality_option: OptionButton = get_node_or_null("%CloudQualityOption")
@onready var cloud_density_slider: HSlider = get_node_or_null("%CloudDensitySlider")
@onready var cloud_density_spin: SpinBox = get_node_or_null("%CloudDensitySpin")
@onready var rain_visual_slider: HSlider = get_node_or_null("%RainVisualSlider")
@onready var rain_visual_spin: SpinBox = get_node_or_null("%RainVisualSpin")

var _hud_presenter = SimulationHudPresenterScript.new()
var _graphics_ui_syncing := false

func _ready() -> void:
	if perf_label == null:
		return
	perf_label.visible = show_performance_overlay
	_hud_presenter.configure(
		self,
		show_performance_overlay,
		performance_server_path,
		Callable(self, "set_performance_text")
	)
	_hud_presenter.bind_performance_server()
	_initialize_graphics_controls()

func _initialize_graphics_controls() -> void:
	if graphics_button != null:
		graphics_button.text = "Graphics"
	if cloud_quality_option != null and cloud_quality_option.item_count == 0:
		cloud_quality_option.add_item("Low")
		cloud_quality_option.add_item("Medium")
		cloud_quality_option.add_item("High")
		cloud_quality_option.add_item("Ultra")
	if graphics_panel != null:
		graphics_panel.visible = false

func set_status_text(text: String) -> void:
	status_label.text = text

func set_details_text(text: String) -> void:
	if details_label == null:
		return
	details_label.text = text

func set_performance_text(text: String) -> void:
	if perf_label == null:
		return
	perf_label.text = text

func set_sim_timing_text(text: String) -> void:
	if sim_timing_label == null:
		return
	sim_timing_label.text = text

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

func set_graphics_label(text: String) -> void:
	if graphics_button == null:
		return
	graphics_button.text = text

func set_graphics_state(state: Dictionary) -> void:
	_graphics_ui_syncing = true
	if water_shader_check != null:
		water_shader_check.button_pressed = bool(state.get("water_shader_enabled", false))
	if ocean_surface_check != null:
		ocean_surface_check.button_pressed = bool(state.get("ocean_surface_enabled", false))
	if river_overlays_check != null:
		river_overlays_check.button_pressed = bool(state.get("river_overlays_enabled", false))
	if rain_post_fx_check != null:
		rain_post_fx_check.button_pressed = bool(state.get("rain_post_fx_enabled", false))
	if clouds_check != null:
		clouds_check.button_pressed = bool(state.get("clouds_enabled", false))
	if shadows_check != null:
		shadows_check.button_pressed = bool(state.get("shadows_enabled", false))
	if ssr_check != null:
		ssr_check.button_pressed = bool(state.get("ssr_enabled", false))
	if ssao_check != null:
		ssao_check.button_pressed = bool(state.get("ssao_enabled", false))
	if ssil_check != null:
		ssil_check.button_pressed = bool(state.get("ssil_enabled", false))
	if sdfgi_check != null:
		sdfgi_check.button_pressed = bool(state.get("sdfgi_enabled", false))
	if glow_check != null:
		glow_check.button_pressed = bool(state.get("glow_enabled", false))
	if fog_check != null:
		fog_check.button_pressed = bool(state.get("fog_enabled", false))
	if volumetric_fog_check != null:
		volumetric_fog_check.button_pressed = bool(state.get("volumetric_fog_enabled", false))
	if cloud_quality_option != null:
		var quality = String(state.get("cloud_quality", "low")).to_lower().strip_edges()
		var idx = 0
		match quality:
			"medium":
				idx = 1
			"high":
				idx = 2
			"ultra":
				idx = 3
		cloud_quality_option.select(idx)
	var cloud_density = clampf(float(state.get("cloud_density_scale", 0.25)), 0.2, 2.0)
	if cloud_density_slider != null:
		cloud_density_slider.value = cloud_density
	if cloud_density_spin != null:
		cloud_density_spin.value = cloud_density
	var rain_visual = clampf(float(state.get("rain_visual_intensity_scale", 0.25)), 0.1, 1.5)
	if rain_visual_slider != null:
		rain_visual_slider.value = rain_visual
	if rain_visual_spin != null:
		rain_visual_spin.value = rain_visual
	_graphics_ui_syncing = false

func _on_graphics_button_pressed() -> void:
	if graphics_panel == null:
		return
	graphics_panel.visible = not graphics_panel.visible

func _on_graphics_toggle(_pressed: bool) -> void:
	if _graphics_ui_syncing:
		return
	_emit_toggle("water_shader_enabled", water_shader_check)
	_emit_toggle("ocean_surface_enabled", ocean_surface_check)
	_emit_toggle("river_overlays_enabled", river_overlays_check)
	_emit_toggle("rain_post_fx_enabled", rain_post_fx_check)
	_emit_toggle("clouds_enabled", clouds_check)
	_emit_toggle("shadows_enabled", shadows_check)
	_emit_toggle("ssr_enabled", ssr_check)
	_emit_toggle("ssao_enabled", ssao_check)
	_emit_toggle("ssil_enabled", ssil_check)
	_emit_toggle("sdfgi_enabled", sdfgi_check)
	_emit_toggle("glow_enabled", glow_check)
	_emit_toggle("fog_enabled", fog_check)
	_emit_toggle("volumetric_fog_enabled", volumetric_fog_check)

func _emit_toggle(option_id: String, checkbox: CheckBox) -> void:
	if checkbox == null:
		return
	emit_signal("graphics_option_changed", option_id, checkbox.button_pressed)

func _on_cloud_quality_selected(index: int) -> void:
	if _graphics_ui_syncing:
		return
	var tier = "low"
	match index:
		1:
			tier = "medium"
		2:
			tier = "high"
		3:
			tier = "ultra"
	emit_signal("graphics_option_changed", "cloud_quality", tier)

func _on_cloud_density_slider_changed(value: float) -> void:
	if _graphics_ui_syncing:
		return
	_graphics_ui_syncing = true
	if cloud_density_spin != null:
		cloud_density_spin.value = value
	_graphics_ui_syncing = false
	emit_signal("graphics_option_changed", "cloud_density_scale", value)

func _on_cloud_density_spin_changed(value: float) -> void:
	if _graphics_ui_syncing:
		return
	_graphics_ui_syncing = true
	if cloud_density_slider != null:
		cloud_density_slider.value = value
	_graphics_ui_syncing = false
	emit_signal("graphics_option_changed", "cloud_density_scale", value)

func _on_rain_visual_slider_changed(value: float) -> void:
	if _graphics_ui_syncing:
		return
	_graphics_ui_syncing = true
	if rain_visual_spin != null:
		rain_visual_spin.value = value
	_graphics_ui_syncing = false
	emit_signal("graphics_option_changed", "rain_visual_intensity_scale", value)

func _on_rain_visual_spin_changed(value: float) -> void:
	if _graphics_ui_syncing:
		return
	_graphics_ui_syncing = true
	if rain_visual_slider != null:
		rain_visual_slider.value = value
	_graphics_ui_syncing = false
	emit_signal("graphics_option_changed", "rain_visual_intensity_scale", value)

func _on_performance_mode_button_pressed() -> void:
	emit_signal("performance_mode_requested")

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
