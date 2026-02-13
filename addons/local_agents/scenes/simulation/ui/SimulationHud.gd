extends CanvasLayer
const SimulationHudPresenterScript = preload("res://addons/local_agents/scenes/simulation/ui/SimulationHudPresenter.gd")
const SimulationGraphicsSettingsScript = preload("res://addons/local_agents/scenes/simulation/controllers/SimulationGraphicsSettings.gd")
const SimulationTimingGraphScript = preload("res://addons/local_agents/scenes/simulation/ui/SimulationTimingGraph.gd")

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
@onready var terrain_chunk_size_slider: HSlider = get_node_or_null("%TerrainChunkSizeSlider")
@onready var terrain_chunk_size_spin: SpinBox = get_node_or_null("%TerrainChunkSizeSpin")
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
@onready var simulation_rate_override_enabled_check: CheckBox = get_node_or_null("%SimRateOverrideCheck")
@onready var perf_sim_tick_rate_slider: HSlider = get_node_or_null("%SimulationTickRateSlider")
@onready var perf_sim_tick_rate_spin: SpinBox = get_node_or_null("%SimulationTickRateSpin")
@onready var weather_solver_decimation_enabled_check: CheckBox = get_node_or_null("%WeatherSolverDecimationCheck")
@onready var hydrology_solver_decimation_enabled_check: CheckBox = get_node_or_null("%HydrologySolverDecimationCheck")
@onready var erosion_solver_decimation_enabled_check: CheckBox = get_node_or_null("%ErosionSolverDecimationCheck")
@onready var solar_solver_decimation_enabled_check: CheckBox = get_node_or_null("%SolarSolverDecimationCheck")
@onready var climate_fast_interval_ticks_slider: HSlider = get_node_or_null("%ClimateFastIntervalSlider")
@onready var climate_fast_interval_ticks_spin: SpinBox = get_node_or_null("%ClimateFastIntervalSpin")
@onready var climate_slow_interval_ticks_slider: HSlider = get_node_or_null("%ClimateSlowIntervalSlider")
@onready var climate_slow_interval_ticks_spin: SpinBox = get_node_or_null("%ClimateSlowIntervalSpin")
@onready var resource_pipeline_decimation_enabled_check: CheckBox = get_node_or_null("%ResourcePipelineDecimationCheck")
@onready var structure_lifecycle_decimation_enabled_check: CheckBox = get_node_or_null("%StructureLifecycleDecimationCheck")
@onready var culture_cycle_decimation_enabled_check: CheckBox = get_node_or_null("%CultureCycleDecimationCheck")
@onready var society_fast_interval_ticks_slider: HSlider = get_node_or_null("%SocietyFastIntervalSlider")
@onready var society_fast_interval_ticks_spin: SpinBox = get_node_or_null("%SocietyFastIntervalSpin")
@onready var society_slow_interval_ticks_slider: HSlider = get_node_or_null("%SocietySlowIntervalSlider")
@onready var society_slow_interval_ticks_spin: SpinBox = get_node_or_null("%SocietySlowIntervalSpin")
@onready var weather_texture_upload_decimation_enabled_check: CheckBox = get_node_or_null("%WeatherTextureUploadDecimationCheck")
@onready var surface_texture_upload_decimation_enabled_check: CheckBox = get_node_or_null("%SurfaceTextureUploadDecimationCheck")
@onready var solar_texture_upload_decimation_enabled_check: CheckBox = get_node_or_null("%SolarTextureUploadDecimationCheck")
@onready var texture_upload_interval_ticks_slider: HSlider = get_node_or_null("%TextureUploadIntervalSlider")
@onready var texture_upload_interval_ticks_spin: SpinBox = get_node_or_null("%TextureUploadIntervalSpin")
@onready var perf_texture_budget_slider: HSlider = get_node_or_null("%TextureUploadBudgetSlider")
@onready var perf_texture_budget_spin: SpinBox = get_node_or_null("%TextureUploadBudgetSpin")
@onready var ecology_step_decimation_enabled_check: CheckBox = get_node_or_null("%EcologyStepDecimationCheck")
@onready var perf_ecology_step_slider: HSlider = get_node_or_null("%EcologyStepIntervalSlider")
@onready var perf_ecology_step_spin: SpinBox = get_node_or_null("%EcologyStepIntervalSpin")
@onready var ecology_voxel_size_slider: HSlider = get_node_or_null("%EcologyVoxelSizeSlider")
@onready var ecology_voxel_size_spin: SpinBox = get_node_or_null("%EcologyVoxelSizeSpin")
@onready var ecology_vertical_extent_slider: HSlider = get_node_or_null("%EcologyVerticalExtentSlider")
@onready var ecology_vertical_extent_spin: SpinBox = get_node_or_null("%EcologyVerticalExtentSpin")

var _hud_presenter = SimulationHudPresenterScript.new()
var _graphics_ui_syncing := false
var _timing_graph: Control
var _custom_inspector_rows_root: VBoxContainer
var _custom_inspector_rows: Dictionary = {}

func _ready() -> void:
	if perf_label == null:
		return
	perf_label.visible = show_performance_overlay
	_hud_presenter.configure(
		self,
		show_performance_overlay,
		performance_server_path,
		Callable(self, "set_performance_text"),
		Callable(self, "set_performance_metrics")
	)
	_hud_presenter.bind_performance_server()
	_initialize_graphics_controls()
	_ensure_timing_graph()

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

func set_sim_timing_profile(profile: Dictionary) -> void:
	if _timing_graph == null:
		_ensure_timing_graph()
	if _timing_graph != null and _timing_graph.has_method("push_profile"):
		_timing_graph.call("push_profile", profile)

func set_performance_metrics(_metrics: Dictionary) -> void:
	pass

func _ensure_timing_graph() -> void:
	if _timing_graph != null and is_instance_valid(_timing_graph):
		return
	if sim_timing_label == null:
		return
	var parent = sim_timing_label.get_parent()
	if parent == null:
		return
	_timing_graph = SimulationTimingGraphScript.new()
	_timing_graph.name = "SimTimingGraph"
	_timing_graph.custom_minimum_size = Vector2(0.0, 124.0)
	parent.add_child(_timing_graph)
	var insert_index = sim_timing_label.get_index() + 1
	parent.move_child(_timing_graph, insert_index)
	_ensure_custom_inspector_rows_root(parent, insert_index + 1)

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
	state = SimulationGraphicsSettingsScript.merge_with_defaults(state)
	_graphics_ui_syncing = true
	if water_shader_check != null:
		water_shader_check.button_pressed = bool(state.get("water_shader_enabled", false))
	if ocean_surface_check != null:
		ocean_surface_check.button_pressed = bool(state.get("ocean_surface_enabled", false))
	if river_overlays_check != null:
		river_overlays_check.button_pressed = bool(state.get("river_overlays_enabled", false))
	if terrain_chunk_size_slider != null:
		terrain_chunk_size_slider.value = float(state.get("terrain_chunk_size_blocks", 12))
	if terrain_chunk_size_spin != null:
		terrain_chunk_size_spin.value = float(state.get("terrain_chunk_size_blocks", 12))
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
	if simulation_rate_override_enabled_check != null:
		simulation_rate_override_enabled_check.button_pressed = bool(state.get("simulation_rate_override_enabled", false))
	if perf_sim_tick_rate_slider != null:
		perf_sim_tick_rate_slider.value = float(state.get("simulation_ticks_per_second_override", 2.0))
	if perf_sim_tick_rate_spin != null:
		perf_sim_tick_rate_spin.value = float(state.get("simulation_ticks_per_second_override", 2.0))
	if weather_solver_decimation_enabled_check != null:
		weather_solver_decimation_enabled_check.button_pressed = bool(state.get("weather_solver_decimation_enabled", false))
	if hydrology_solver_decimation_enabled_check != null:
		hydrology_solver_decimation_enabled_check.button_pressed = bool(state.get("hydrology_solver_decimation_enabled", false))
	if erosion_solver_decimation_enabled_check != null:
		erosion_solver_decimation_enabled_check.button_pressed = bool(state.get("erosion_solver_decimation_enabled", false))
	if solar_solver_decimation_enabled_check != null:
		solar_solver_decimation_enabled_check.button_pressed = bool(state.get("solar_solver_decimation_enabled", false))
	if climate_fast_interval_ticks_slider != null:
		climate_fast_interval_ticks_slider.value = float(state.get("climate_fast_interval_ticks", 4))
	if climate_fast_interval_ticks_spin != null:
		climate_fast_interval_ticks_spin.value = float(state.get("climate_fast_interval_ticks", 4))
	if climate_slow_interval_ticks_slider != null:
		climate_slow_interval_ticks_slider.value = float(state.get("climate_slow_interval_ticks", 8))
	if climate_slow_interval_ticks_spin != null:
		climate_slow_interval_ticks_spin.value = float(state.get("climate_slow_interval_ticks", 8))
	if resource_pipeline_decimation_enabled_check != null:
		resource_pipeline_decimation_enabled_check.button_pressed = bool(state.get("resource_pipeline_decimation_enabled", false))
	if structure_lifecycle_decimation_enabled_check != null:
		structure_lifecycle_decimation_enabled_check.button_pressed = bool(state.get("structure_lifecycle_decimation_enabled", false))
	if culture_cycle_decimation_enabled_check != null:
		culture_cycle_decimation_enabled_check.button_pressed = bool(state.get("culture_cycle_decimation_enabled", false))
	if society_fast_interval_ticks_slider != null:
		society_fast_interval_ticks_slider.value = float(state.get("society_fast_interval_ticks", 4))
	if society_fast_interval_ticks_spin != null:
		society_fast_interval_ticks_spin.value = float(state.get("society_fast_interval_ticks", 4))
	if society_slow_interval_ticks_slider != null:
		society_slow_interval_ticks_slider.value = float(state.get("society_slow_interval_ticks", 8))
	if society_slow_interval_ticks_spin != null:
		society_slow_interval_ticks_spin.value = float(state.get("society_slow_interval_ticks", 8))
	if weather_texture_upload_decimation_enabled_check != null:
		weather_texture_upload_decimation_enabled_check.button_pressed = bool(state.get("weather_texture_upload_decimation_enabled", false))
	if surface_texture_upload_decimation_enabled_check != null:
		surface_texture_upload_decimation_enabled_check.button_pressed = bool(state.get("surface_texture_upload_decimation_enabled", false))
	if solar_texture_upload_decimation_enabled_check != null:
		solar_texture_upload_decimation_enabled_check.button_pressed = bool(state.get("solar_texture_upload_decimation_enabled", false))
	if texture_upload_interval_ticks_slider != null:
		texture_upload_interval_ticks_slider.value = float(state.get("texture_upload_interval_ticks", 8))
	if texture_upload_interval_ticks_spin != null:
		texture_upload_interval_ticks_spin.value = float(state.get("texture_upload_interval_ticks", 8))
	if perf_texture_budget_slider != null:
		perf_texture_budget_slider.value = float(state.get("texture_upload_budget_texels", 4096))
	if perf_texture_budget_spin != null:
		perf_texture_budget_spin.value = float(state.get("texture_upload_budget_texels", 4096))
	if ecology_step_decimation_enabled_check != null:
		ecology_step_decimation_enabled_check.button_pressed = bool(state.get("ecology_step_decimation_enabled", false))
	if perf_ecology_step_slider != null:
		perf_ecology_step_slider.value = float(state.get("ecology_step_interval_seconds", 0.2))
	if perf_ecology_step_spin != null:
		perf_ecology_step_spin.value = float(state.get("ecology_step_interval_seconds", 0.2))
	var ecology_voxel_size = clampf(float(state.get("ecology_voxel_size_meters", 1.0)), 0.5, 3.0)
	if ecology_voxel_size_slider != null:
		ecology_voxel_size_slider.value = ecology_voxel_size
	if ecology_voxel_size_spin != null:
		ecology_voxel_size_spin.value = ecology_voxel_size
	var ecology_vertical_extent = clampf(float(state.get("ecology_vertical_extent_meters", 3.0)), 1.0, 8.0)
	if ecology_vertical_extent_slider != null:
		ecology_vertical_extent_slider.value = ecology_vertical_extent
	if ecology_vertical_extent_spin != null:
		ecology_vertical_extent_spin.value = ecology_vertical_extent
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
	_emit_toggle("simulation_rate_override_enabled", simulation_rate_override_enabled_check)
	_emit_toggle("weather_solver_decimation_enabled", weather_solver_decimation_enabled_check)
	_emit_toggle("hydrology_solver_decimation_enabled", hydrology_solver_decimation_enabled_check)
	_emit_toggle("erosion_solver_decimation_enabled", erosion_solver_decimation_enabled_check)
	_emit_toggle("solar_solver_decimation_enabled", solar_solver_decimation_enabled_check)
	_emit_toggle("resource_pipeline_decimation_enabled", resource_pipeline_decimation_enabled_check)
	_emit_toggle("structure_lifecycle_decimation_enabled", structure_lifecycle_decimation_enabled_check)
	_emit_toggle("culture_cycle_decimation_enabled", culture_cycle_decimation_enabled_check)
	_emit_toggle("weather_texture_upload_decimation_enabled", weather_texture_upload_decimation_enabled_check)
	_emit_toggle("surface_texture_upload_decimation_enabled", surface_texture_upload_decimation_enabled_check)
	_emit_toggle("solar_texture_upload_decimation_enabled", solar_texture_upload_decimation_enabled_check)
	_emit_toggle("ecology_step_decimation_enabled", ecology_step_decimation_enabled_check)

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

func _on_terrain_chunk_size_slider_changed(value: float) -> void:
	_sync_perf_interval_pair(value, terrain_chunk_size_slider, terrain_chunk_size_spin, "terrain_chunk_size_blocks")

func _on_terrain_chunk_size_spin_changed(value: float) -> void:
	_sync_perf_interval_pair(value, terrain_chunk_size_slider, terrain_chunk_size_spin, "terrain_chunk_size_blocks")

func _on_perf_sim_tick_rate_slider_changed(value: float) -> void:
	if _graphics_ui_syncing:
		return
	_graphics_ui_syncing = true
	if perf_sim_tick_rate_spin != null:
		perf_sim_tick_rate_spin.value = value
	_graphics_ui_syncing = false
	emit_signal("graphics_option_changed", "simulation_ticks_per_second_override", value)

func _on_perf_sim_tick_rate_spin_changed(value: float) -> void:
	if _graphics_ui_syncing:
		return
	_graphics_ui_syncing = true
	if perf_sim_tick_rate_slider != null:
		perf_sim_tick_rate_slider.value = value
	_graphics_ui_syncing = false
	emit_signal("graphics_option_changed", "simulation_ticks_per_second_override", value)

func _on_perf_climate_fast_interval_slider_changed(value: float) -> void:
	_sync_perf_interval_pair(value, climate_fast_interval_ticks_slider, climate_fast_interval_ticks_spin, "climate_fast_interval_ticks")

func _on_perf_climate_fast_interval_spin_changed(value: float) -> void:
	_sync_perf_interval_pair(value, climate_fast_interval_ticks_slider, climate_fast_interval_ticks_spin, "climate_fast_interval_ticks")

func _on_perf_climate_slow_interval_slider_changed(value: float) -> void:
	_sync_perf_interval_pair(value, climate_slow_interval_ticks_slider, climate_slow_interval_ticks_spin, "climate_slow_interval_ticks")

func _on_perf_climate_slow_interval_spin_changed(value: float) -> void:
	_sync_perf_interval_pair(value, climate_slow_interval_ticks_slider, climate_slow_interval_ticks_spin, "climate_slow_interval_ticks")

func _on_perf_society_fast_interval_slider_changed(value: float) -> void:
	_sync_perf_interval_pair(value, society_fast_interval_ticks_slider, society_fast_interval_ticks_spin, "society_fast_interval_ticks")

func _on_perf_society_fast_interval_spin_changed(value: float) -> void:
	_sync_perf_interval_pair(value, society_fast_interval_ticks_slider, society_fast_interval_ticks_spin, "society_fast_interval_ticks")

func _on_perf_society_slow_interval_slider_changed(value: float) -> void:
	_sync_perf_interval_pair(value, society_slow_interval_ticks_slider, society_slow_interval_ticks_spin, "society_slow_interval_ticks")

func _on_perf_society_slow_interval_spin_changed(value: float) -> void:
	_sync_perf_interval_pair(value, society_slow_interval_ticks_slider, society_slow_interval_ticks_spin, "society_slow_interval_ticks")

func _on_perf_texture_interval_slider_changed(value: float) -> void:
	_sync_perf_interval_pair(value, texture_upload_interval_ticks_slider, texture_upload_interval_ticks_spin, "texture_upload_interval_ticks")

func _on_perf_texture_interval_spin_changed(value: float) -> void:
	_sync_perf_interval_pair(value, texture_upload_interval_ticks_slider, texture_upload_interval_ticks_spin, "texture_upload_interval_ticks")

func _on_perf_texture_budget_slider_changed(value: float) -> void:
	if _graphics_ui_syncing:
		return
	var snapped = round(value / 512.0) * 512.0
	_graphics_ui_syncing = true
	if perf_texture_budget_slider != null:
		perf_texture_budget_slider.value = snapped
	if perf_texture_budget_spin != null:
		perf_texture_budget_spin.value = snapped
	_graphics_ui_syncing = false
	emit_signal("graphics_option_changed", "texture_upload_budget_texels", int(snapped))

func _on_perf_texture_budget_spin_changed(value: float) -> void:
	_on_perf_texture_budget_slider_changed(value)

func _on_perf_ecology_step_slider_changed(value: float) -> void:
	if _graphics_ui_syncing:
		return
	_graphics_ui_syncing = true
	if perf_ecology_step_spin != null:
		perf_ecology_step_spin.value = value
	_graphics_ui_syncing = false
	emit_signal("graphics_option_changed", "ecology_step_interval_seconds", value)

func _on_perf_ecology_step_spin_changed(value: float) -> void:
	if _graphics_ui_syncing:
		return
	_graphics_ui_syncing = true
	if perf_ecology_step_slider != null:
		perf_ecology_step_slider.value = value
	_graphics_ui_syncing = false
	emit_signal("graphics_option_changed", "ecology_step_interval_seconds", value)

func _on_ecology_voxel_size_slider_changed(value: float) -> void:
	if _graphics_ui_syncing:
		return
	_graphics_ui_syncing = true
	if ecology_voxel_size_spin != null:
		ecology_voxel_size_spin.value = value
	_graphics_ui_syncing = false
	emit_signal("graphics_option_changed", "ecology_voxel_size_meters", value)

func _on_ecology_voxel_size_spin_changed(value: float) -> void:
	if _graphics_ui_syncing:
		return
	_graphics_ui_syncing = true
	if ecology_voxel_size_slider != null:
		ecology_voxel_size_slider.value = value
	_graphics_ui_syncing = false
	emit_signal("graphics_option_changed", "ecology_voxel_size_meters", value)

func _on_ecology_vertical_extent_slider_changed(value: float) -> void:
	if _graphics_ui_syncing:
		return
	_graphics_ui_syncing = true
	if ecology_vertical_extent_spin != null:
		ecology_vertical_extent_spin.value = value
	_graphics_ui_syncing = false
	emit_signal("graphics_option_changed", "ecology_vertical_extent_meters", value)

func _on_ecology_vertical_extent_spin_changed(value: float) -> void:
	if _graphics_ui_syncing:
		return
	_graphics_ui_syncing = true
	if ecology_vertical_extent_slider != null:
		ecology_vertical_extent_slider.value = value
	_graphics_ui_syncing = false
	emit_signal("graphics_option_changed", "ecology_vertical_extent_meters", value)

func _sync_perf_interval_pair(value: float, slider: HSlider, spin: SpinBox, option_id: String) -> void:
	if _graphics_ui_syncing:
		return
	var ivalue = int(round(value))
	_graphics_ui_syncing = true
	if slider != null:
		slider.value = ivalue
	if spin != null:
		spin.value = ivalue
	_graphics_ui_syncing = false
	emit_signal("graphics_option_changed", option_id, ivalue)


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
