extends RefCounted

const SimulationGraphicsSettingsScript = preload("res://addons/local_agents/scenes/simulation/controllers/SimulationGraphicsSettings.gd")

const FRAME_GRAPH_TOGGLE_ROWS := [
	{"key": "frame_graph_total_enabled", "label": "Total", "series": "total_ms", "color": Color(1.0, 1.0, 1.0, 0.95)},
	{"key": "frame_graph_transform_stage_a_enabled", "label": "Transform Stage A", "series": "transform_stage_a_ms", "color": Color(0.35, 0.78, 1.0, 0.9)},
	{"key": "frame_graph_transform_stage_b_enabled", "label": "Transform Stage B", "series": "transform_stage_b_ms", "color": Color(0.2, 1.0, 0.95, 0.9)},
	{"key": "frame_graph_transform_stage_c_enabled", "label": "Transform Stage C", "series": "transform_stage_c_ms", "color": Color(0.95, 0.62, 0.24, 0.9)},
	{"key": "frame_graph_transform_stage_d_enabled", "label": "Transform Stage D", "series": "transform_stage_d_ms", "color": Color(1.0, 0.92, 0.28, 0.9)},
	{"key": "frame_graph_resource_pipeline_enabled", "label": "Resource", "series": "resource_pipeline_ms", "color": Color(0.5, 1.0, 0.44, 0.9)},
	{"key": "frame_graph_structure_enabled", "label": "Structure", "series": "structure_ms", "color": Color(0.95, 0.45, 0.8, 0.9)},
	{"key": "frame_graph_culture_enabled", "label": "Culture", "series": "culture_ms", "color": Color(0.88, 0.72, 1.0, 0.9)},
	{"key": "frame_graph_cognition_enabled", "label": "Cognition", "series": "cognition_ms", "color": Color(1.0, 0.36, 0.36, 0.9)},
	{"key": "frame_graph_snapshot_enabled", "label": "Snapshot", "series": "snapshot_ms", "color": Color(0.82, 0.82, 0.82, 0.8)},
]

const SYSTEM_ENABLE_TOGGLE_ROWS := [
	{"key": "transform_stage_a_system_enabled", "label": "Transform Stage A"},
	{"key": "transform_stage_b_system_enabled", "label": "Transform Stage B"},
	{"key": "transform_stage_c_system_enabled", "label": "Transform Stage C"},
	{"key": "transform_stage_d_system_enabled", "label": "Transform Stage D"},
	{"key": "resource_pipeline_enabled", "label": "Resource Pipeline"},
	{"key": "structure_lifecycle_enabled", "label": "Structure Lifecycle"},
	{"key": "culture_cycle_enabled", "label": "Culture Cycle"},
	{"key": "ecology_system_enabled", "label": "Ecology"},
	{"key": "settlement_system_enabled", "label": "Settlement View"},
	{"key": "villager_system_enabled", "label": "Villagers"},
	{"key": "cognition_system_enabled", "label": "Cognition"},
]

const GPU_COMPUTE_TOGGLE_ROWS := [
	{"key": "transform_stage_a_gpu_compute_enabled", "label": "Transform Stage A GPU"},
	{"key": "transform_stage_b_gpu_compute_enabled", "label": "Transform Stage B GPU"},
	{"key": "transform_stage_c_gpu_compute_enabled", "label": "Transform Stage C GPU"},
	{"key": "transform_stage_d_gpu_compute_enabled", "label": "Transform Stage D GPU"},
]

var _hud: CanvasLayer
var _emit_graphics_option_changed: Callable
var _set_frame_series_visible: Callable

var _graphics_ui_syncing := false
var _graphics_button: Button
var _graphics_panel: PanelContainer
var _graphics_vbox: VBoxContainer
var _cloud_quality_option: OptionButton
var _cloud_density_slider: HSlider
var _cloud_density_spin: SpinBox
var _rain_visual_slider: HSlider
var _rain_visual_spin: SpinBox

var _frame_graph_checkboxes: Dictionary = {}
var _toggle_controls: Dictionary = {}
var _pair_controls: Dictionary = {}

func configure(hud: CanvasLayer, emit_graphics_option_changed: Callable, set_frame_series_visible: Callable) -> void:
	_hud = hud
	_emit_graphics_option_changed = emit_graphics_option_changed
	_set_frame_series_visible = set_frame_series_visible
	_bind_nodes()
	_initialize_graphics_controls()

func set_graphics_label(text: String) -> void:
	if _graphics_button == null:
		return
	_graphics_button.text = text

func set_graphics_state(state: Dictionary) -> void:
	state = SimulationGraphicsSettingsScript.merge_with_defaults(state)
	_graphics_ui_syncing = true
	for option_id in _toggle_controls.keys():
		var checkbox: CheckBox = _toggle_controls.get(option_id, null)
		if checkbox != null:
			checkbox.button_pressed = bool(state.get(option_id, false))
	_set_pair_value("terrain_chunk_size_blocks", float(state.get("terrain_chunk_size_blocks", 12.0)))
	_set_pair_value("simulation_ticks_per_second_override", float(state.get("simulation_ticks_per_second_override", 2.0)))
	_set_pair_value("simulation_locality_radius_tiles", float(maxi(0, int(state.get("simulation_locality_radius_tiles", 1)))))
	_set_pair_value("pillar_height_scale", clampf(float(state.get("pillar_height_scale", 1.0)), 0.25, 3.0))
	_set_pair_value("pillar_density_scale", clampf(float(state.get("pillar_density_scale", 1.0)), 0.25, 3.0))
	_set_pair_value("wall_brittleness_scale", clampf(float(state.get("wall_brittleness_scale", 1.0)), 0.1, 3.0))
	_set_pair_value("climate_fast_interval_ticks", float(state.get("climate_fast_interval_ticks", 4.0)))
	_set_pair_value("climate_slow_interval_ticks", float(state.get("climate_slow_interval_ticks", 8.0)))
	_set_pair_value("society_fast_interval_ticks", float(state.get("society_fast_interval_ticks", 4.0)))
	_set_pair_value("society_slow_interval_ticks", float(state.get("society_slow_interval_ticks", 8.0)))
	_set_pair_value("texture_upload_interval_ticks", float(state.get("texture_upload_interval_ticks", 8.0)))
	_set_pair_value("texture_upload_budget_texels", float(state.get("texture_upload_budget_texels", 4096.0)))
	_set_pair_value("ecology_step_interval_seconds", float(state.get("ecology_step_interval_seconds", 0.2)))
	_set_pair_value("ecology_voxel_size_meters", clampf(float(state.get("ecology_voxel_size_meters", 1.0)), 0.5, 3.0))
	_set_pair_value("ecology_vertical_extent_meters", clampf(float(state.get("ecology_vertical_extent_meters", 3.0)), 1.0, 8.0))
	_set_pair_value("voxel_tick_min_interval_seconds", clampf(float(state.get("voxel_tick_min_interval_seconds", 0.05)), 0.01, 1.2))
	_set_pair_value("voxel_tick_max_interval_seconds", clampf(float(state.get("voxel_tick_max_interval_seconds", 0.6)), 0.02, 3.0))
	_set_pair_value("voxel_smell_step_radius_cells", float(maxi(1, int(state.get("voxel_smell_step_radius_cells", 1)))))
	_set_pair_value("smell_query_top_k_per_layer", float(maxi(8, int(state.get("smell_query_top_k_per_layer", 48)))))
	_set_pair_value("smell_query_update_interval_seconds", clampf(float(state.get("smell_query_update_interval_seconds", 0.25)), 0.01, 2.0))
	_apply_cloud_quality(state)
	_set_cloud_density(float(state.get("cloud_density_scale", 0.25)))
	_set_rain_visual(float(state.get("rain_visual_intensity_scale", 0.25)))
	for row in FRAME_GRAPH_TOGGLE_ROWS:
		var key := String(row.get("key", ""))
		var check: CheckBox = _frame_graph_checkboxes.get(key, null)
		if check != null:
			check.button_pressed = bool(state.get(key, true))
	_graphics_ui_syncing = false
	_apply_frame_graph_visibility(state)

func on_graphics_button_pressed() -> void:
	if _graphics_panel == null:
		return
	_graphics_panel.visible = not _graphics_panel.visible

func on_graphics_toggle() -> void:
	if _graphics_ui_syncing:
		return
	for option_id in _toggle_controls.keys():
		_emit_toggle(option_id, _toggle_controls.get(option_id, null))

func on_frame_graph_toggle_changed(option_id: String) -> void:
	if _graphics_ui_syncing:
		return
	var check: CheckBox = _frame_graph_checkboxes.get(option_id, null)
	if check == null:
		return
	_emit_option(option_id, check.button_pressed)
	_apply_frame_graph_visibility({option_id: check.button_pressed})

func on_cloud_quality_selected(index: int) -> void:
	if _graphics_ui_syncing:
		return
	var tier := "low"
	match index:
		1:
			tier = "medium"
		2:
			tier = "high"
		3:
			tier = "ultra"
	_emit_option("cloud_quality", tier)

func on_cloud_density_slider_changed(value: float) -> void:
	_sync_float_pair(value, _cloud_density_slider, _cloud_density_spin, "cloud_density_scale")

func on_cloud_density_spin_changed(value: float) -> void:
	_sync_float_pair(value, _cloud_density_slider, _cloud_density_spin, "cloud_density_scale")

func on_rain_visual_slider_changed(value: float) -> void:
	_sync_float_pair(value, _rain_visual_slider, _rain_visual_spin, "rain_visual_intensity_scale")

func on_rain_visual_spin_changed(value: float) -> void:
	_sync_float_pair(value, _rain_visual_slider, _rain_visual_spin, "rain_visual_intensity_scale")

func on_terrain_chunk_size_changed(value: float) -> void:
	_sync_int_pair(value, "terrain_chunk_size_blocks")

func on_perf_sim_tick_rate_changed(value: float) -> void:
	_sync_float_pair_by_option(value, "simulation_ticks_per_second_override")

func on_perf_climate_fast_interval_changed(value: float) -> void:
	_sync_int_pair(value, "climate_fast_interval_ticks")

func on_perf_climate_slow_interval_changed(value: float) -> void:
	_sync_int_pair(value, "climate_slow_interval_ticks")

func on_perf_society_fast_interval_changed(value: float) -> void:
	_sync_int_pair(value, "society_fast_interval_ticks")

func on_perf_society_slow_interval_changed(value: float) -> void:
	_sync_int_pair(value, "society_slow_interval_ticks")

func on_perf_texture_interval_changed(value: float) -> void:
	_sync_int_pair(value, "texture_upload_interval_ticks")

func on_perf_texture_budget_changed(value: float) -> void:
	if _graphics_ui_syncing:
		return
	var snapped: float = round(value / 512.0) * 512.0
	_set_pair_with_sync("texture_upload_budget_texels", snapped)
	_emit_option("texture_upload_budget_texels", int(snapped))

func on_perf_ecology_step_changed(value: float) -> void:
	_sync_float_pair_by_option(value, "ecology_step_interval_seconds")

func on_ecology_voxel_size_changed(value: float) -> void:
	_sync_float_pair_by_option(value, "ecology_voxel_size_meters")

func on_ecology_vertical_extent_changed(value: float) -> void:
	_sync_float_pair_by_option(value, "ecology_vertical_extent_meters")

func _bind_nodes() -> void:
	_graphics_button = _hud.get_node_or_null("%GraphicsButton") as Button
	_graphics_panel = _hud.get_node_or_null("%GraphicsPanel") as PanelContainer
	_graphics_vbox = _hud.get_node_or_null("GraphicsPanel/GraphicsMargin/GraphicsScroll/GraphicsVBox") as VBoxContainer
	_cloud_quality_option = _hud.get_node_or_null("%CloudQualityOption") as OptionButton
	_cloud_density_slider = _hud.get_node_or_null("%CloudDensitySlider") as HSlider
	_cloud_density_spin = _hud.get_node_or_null("%CloudDensitySpin") as SpinBox
	_rain_visual_slider = _hud.get_node_or_null("%RainVisualSlider") as HSlider
	_rain_visual_spin = _hud.get_node_or_null("%RainVisualSpin") as SpinBox

	_toggle_controls = {
		"water_shader_enabled": _hud.get_node_or_null("%WaterShaderCheck") as CheckBox,
		"ocean_surface_enabled": _hud.get_node_or_null("%OceanSurfaceCheck") as CheckBox,
		"river_overlays_enabled": _hud.get_node_or_null("%RiverOverlaysCheck") as CheckBox,
		"rain_post_fx_enabled": _hud.get_node_or_null("%RainPostFxCheck") as CheckBox,
		"clouds_enabled": _hud.get_node_or_null("%CloudsCheck") as CheckBox,
		"shadows_enabled": _hud.get_node_or_null("%ShadowsCheck") as CheckBox,
		"ssr_enabled": _hud.get_node_or_null("%SsrCheck") as CheckBox,
		"ssao_enabled": _hud.get_node_or_null("%SsaoCheck") as CheckBox,
		"ssil_enabled": _hud.get_node_or_null("%SsilCheck") as CheckBox,
		"sdfgi_enabled": _hud.get_node_or_null("%SdfgiCheck") as CheckBox,
		"glow_enabled": _hud.get_node_or_null("%GlowCheck") as CheckBox,
		"fog_enabled": _hud.get_node_or_null("%FogCheck") as CheckBox,
		"volumetric_fog_enabled": _hud.get_node_or_null("%VolumetricFogCheck") as CheckBox,
		"simulation_rate_override_enabled": _hud.get_node_or_null("%SimRateOverrideCheck") as CheckBox,
		"transform_stage_a_solver_decimation_enabled": _hud.get_node_or_null("%TransformStageASolverDecimationCheck") as CheckBox,
		"transform_stage_b_solver_decimation_enabled": _hud.get_node_or_null("%TransformStageBSolverDecimationCheck") as CheckBox,
		"transform_stage_c_solver_decimation_enabled": _hud.get_node_or_null("%ErosionSolverDecimationCheck") as CheckBox,
		"transform_stage_d_solver_decimation_enabled": _hud.get_node_or_null("%TransformStageDSolverDecimationCheck") as CheckBox,
		"resource_pipeline_decimation_enabled": _hud.get_node_or_null("%ResourcePipelineDecimationCheck") as CheckBox,
		"structure_lifecycle_decimation_enabled": _hud.get_node_or_null("%StructureLifecycleDecimationCheck") as CheckBox,
		"culture_cycle_decimation_enabled": _hud.get_node_or_null("%CultureCycleDecimationCheck") as CheckBox,
		"transform_stage_a_texture_upload_decimation_enabled": _hud.get_node_or_null("%TransformStageATextureUploadDecimationCheck") as CheckBox,
		"transform_stage_b_texture_upload_decimation_enabled": _hud.get_node_or_null("%SurfaceTextureUploadDecimationCheck") as CheckBox,
		"transform_stage_d_texture_upload_decimation_enabled": _hud.get_node_or_null("%TransformStageDTextureUploadDecimationCheck") as CheckBox,
		"ecology_step_decimation_enabled": _hud.get_node_or_null("%EcologyStepDecimationCheck") as CheckBox,
	}

	_pair_controls = {
		"terrain_chunk_size_blocks": _pair(_hud.get_node_or_null("%TerrainChunkSizeSlider") as HSlider, _hud.get_node_or_null("%TerrainChunkSizeSpin") as SpinBox),
		"simulation_ticks_per_second_override": _pair(_hud.get_node_or_null("%SimulationTickRateSlider") as HSlider, _hud.get_node_or_null("%SimulationTickRateSpin") as SpinBox),
		"climate_fast_interval_ticks": _pair(_hud.get_node_or_null("%ClimateFastIntervalSlider") as HSlider, _hud.get_node_or_null("%ClimateFastIntervalSpin") as SpinBox),
		"climate_slow_interval_ticks": _pair(_hud.get_node_or_null("%ClimateSlowIntervalSlider") as HSlider, _hud.get_node_or_null("%ClimateSlowIntervalSpin") as SpinBox),
		"society_fast_interval_ticks": _pair(_hud.get_node_or_null("%SocietyFastIntervalSlider") as HSlider, _hud.get_node_or_null("%SocietyFastIntervalSpin") as SpinBox),
		"society_slow_interval_ticks": _pair(_hud.get_node_or_null("%SocietySlowIntervalSlider") as HSlider, _hud.get_node_or_null("%SocietySlowIntervalSpin") as SpinBox),
		"texture_upload_interval_ticks": _pair(_hud.get_node_or_null("%TextureUploadIntervalSlider") as HSlider, _hud.get_node_or_null("%TextureUploadIntervalSpin") as SpinBox),
		"texture_upload_budget_texels": _pair(_hud.get_node_or_null("%TextureUploadBudgetSlider") as HSlider, _hud.get_node_or_null("%TextureUploadBudgetSpin") as SpinBox),
		"ecology_step_interval_seconds": _pair(_hud.get_node_or_null("%EcologyStepIntervalSlider") as HSlider, _hud.get_node_or_null("%EcologyStepIntervalSpin") as SpinBox),
		"ecology_voxel_size_meters": _pair(_hud.get_node_or_null("%EcologyVoxelSizeSlider") as HSlider, _hud.get_node_or_null("%EcologyVoxelSizeSpin") as SpinBox),
		"ecology_vertical_extent_meters": _pair(_hud.get_node_or_null("%EcologyVerticalExtentSlider") as HSlider, _hud.get_node_or_null("%EcologyVerticalExtentSpin") as SpinBox),
	}

func _initialize_graphics_controls() -> void:
	if _graphics_button != null:
		_graphics_button.text = "Graphics"
	if _cloud_quality_option != null and _cloud_quality_option.item_count == 0:
		_cloud_quality_option.add_item("Low")
		_cloud_quality_option.add_item("Medium")
		_cloud_quality_option.add_item("High")
		_cloud_quality_option.add_item("Ultra")
	if _graphics_panel != null:
		_graphics_panel.visible = false
	_organize_graphics_layout()

func _organize_graphics_layout() -> void:
	if _graphics_vbox == null:
		return
	var systems_content := _ensure_graphics_section("SystemEnable", "Default Launch & Runtime Systems")
	var render_content := _ensure_graphics_section("RenderEnv", "Render & Environment")
	var sim_content := _ensure_graphics_section("SimulationRate", "Simulation")
	var climate_content := _ensure_graphics_section("ClimatePipeline", "Transform Pipeline")
	var society_content := _ensure_graphics_section("SocietyPipeline", "Society Pipeline")
	var texture_content := _ensure_graphics_section("TextureUploads", "GPU Texture Uploads")
	var ecology_content := _ensure_graphics_section("Ecology", "Ecology")
	var graph_content := _ensure_graphics_section("FrameGraph", "Frame Inspector Graph")
	_ensure_system_enable_controls(systems_content)

	_move_nodes_by_name(render_content, ["WaterShaderCheck", "OceanSurfaceCheck", "RiverOverlaysCheck", "TerrainChunkSizeRow", "RainPostFxCheck", "CloudsCheck", "ShadowsCheck", "SsrCheck", "SsaoCheck", "SsilCheck", "SdfgiCheck", "GlowCheck", "FogCheck", "VolumetricFogCheck", "CloudQualityRow", "CloudDensityRow", "RainVisualRow"])
	_move_nodes_by_name(sim_content, ["SimRateOverrideCheck", "SimulationTickRateRow"])
	_ensure_simulation_locality_controls(sim_content)
	_ensure_gpu_compute_controls(climate_content)
	_move_nodes_by_name(climate_content, ["ClimatePipelineTitle", "TransformStageASolverDecimationCheck", "TransformStageBSolverDecimationCheck", "ErosionSolverDecimationCheck", "TransformStageDSolverDecimationCheck", "ClimateFastIntervalRow", "ClimateSlowIntervalRow"])
	_move_nodes_by_name(society_content, ["SocietyPipelineTitle", "ResourcePipelineDecimationCheck", "StructureLifecycleDecimationCheck", "CultureCycleDecimationCheck", "SocietyFastIntervalRow", "SocietySlowIntervalRow"])
	_move_nodes_by_name(texture_content, ["TextureUploadsTitle", "TransformStageATextureUploadDecimationCheck", "SurfaceTextureUploadDecimationCheck", "TransformStageDTextureUploadDecimationCheck", "TextureUploadIntervalRow", "TextureUploadBudgetRow"])
	_move_nodes_by_name(ecology_content, ["EcologyStepDecimationCheck", "EcologyStepIntervalRow", "EcologyVoxelSizeRow", "EcologyVerticalExtentRow"])
	_ensure_voxel_gating_controls(ecology_content)
	_ensure_frame_graph_toggle_controls(graph_content)

func _ensure_system_enable_controls(parent: VBoxContainer) -> void:
	if parent == null:
		return
	var title = parent.get_node_or_null("SystemEnableTitle") as Label
	if title == null:
		title = Label.new()
		title.name = "SystemEnableTitle"
		title.text = "Default Launch & Runtime Systems"
		parent.add_child(title)
		title.owner = _hud.owner
	for row in SYSTEM_ENABLE_TOGGLE_ROWS:
		var key := String(row.get("key", ""))
		if key == "":
			continue
		_create_dynamic_toggle(parent, key, String(row.get("label", key)))

func _ensure_graphics_section(section_id: String, title: String) -> VBoxContainer:
	if _graphics_vbox == null:
		return null
	var wrapper = _graphics_vbox.get_node_or_null("Section_%s" % section_id)
	if wrapper == null:
		wrapper = VBoxContainer.new()
		wrapper.name = "Section_%s" % section_id
		wrapper.add_theme_constant_override("separation", 4)
		_graphics_vbox.add_child(wrapper)
		wrapper.owner = _hud.owner
	var title_label = wrapper.get_node_or_null("Title_%s" % section_id)
	if title_label == null:
		title_label = Label.new()
		title_label.name = "Title_%s" % section_id
		wrapper.add_child(title_label)
		title_label.owner = _hud.owner
	title_label.text = title
	var content = wrapper.get_node_or_null("Content_%s" % section_id)
	if content == null:
		content = VBoxContainer.new()
		content.name = "Content_%s" % section_id
		content.add_theme_constant_override("separation", 6)
		wrapper.add_child(content)
		content.owner = _hud.owner
	return content as VBoxContainer

func _move_nodes_by_name(target_parent: Node, node_names: Array) -> void:
	if target_parent == null or _graphics_vbox == null:
		return
	for name_variant in node_names:
		var n := _graphics_vbox.find_child(String(name_variant), true, false)
		if n == null or n.get_parent() == target_parent:
			continue
		var keep_owner := n.owner
		var old_parent := n.get_parent()
		if old_parent != null:
			old_parent.remove_child(n)
		target_parent.add_child(n)
		n.owner = keep_owner

func _ensure_frame_graph_toggle_controls(parent: VBoxContainer) -> void:
	if parent == null:
		return
	var grid = parent.get_node_or_null("FrameGraphToggleGrid") as GridContainer
	if grid == null:
		grid = GridContainer.new()
		grid.name = "FrameGraphToggleGrid"
		grid.columns = 2
		parent.add_child(grid)
		grid.owner = _hud.owner
	for row in FRAME_GRAPH_TOGGLE_ROWS:
		var key := String(row.get("key", ""))
		if key == "":
			continue
		var check = grid.get_node_or_null("GraphToggle_%s" % key) as CheckBox
		if check == null:
			check = CheckBox.new()
			check.name = "GraphToggle_%s" % key
			check.text = "■ %s" % String(row.get("label", key))
			check.button_pressed = true
			var color: Color = row.get("color", Color(1.0, 1.0, 1.0, 1.0))
			check.add_theme_color_override("font_color", color)
			check.add_theme_color_override("font_pressed_color", color)
			check.add_theme_color_override("font_hover_color", color)
			check.toggled.connect(_on_frame_graph_checkbox_toggled.bind(key))
			grid.add_child(check)
			check.owner = _hud.owner
		_frame_graph_checkboxes[key] = check

func _ensure_gpu_compute_controls(parent: VBoxContainer) -> void:
	if parent == null:
		return
	var title = parent.get_node_or_null("GpuComputeTitle") as Label
	if title == null:
		title = Label.new()
		title.name = "GpuComputeTitle"
		title.text = "GPU Compute Backends"
		parent.add_child(title)
		title.owner = _hud.owner
	for row in GPU_COMPUTE_TOGGLE_ROWS:
		var key := String(row.get("key", ""))
		if key == "":
			continue
		var check = parent.get_node_or_null("GpuToggle_%s" % key) as CheckBox
		if check == null:
			check = CheckBox.new()
			check.name = "GpuToggle_%s" % key
			check.text = String(row.get("label", key))
			check.button_pressed = true
			check.toggled.connect(_on_gpu_toggle_changed.bind(key))
			parent.add_child(check)
			check.owner = _hud.owner
		_toggle_controls[key] = check

func _ensure_voxel_gating_controls(parent: VBoxContainer) -> void:
	if parent == null:
		return
	var title = parent.get_node_or_null("VoxelGatingTitle") as Label
	if title == null:
		title = Label.new()
		title.name = "VoxelGatingTitle"
		title.text = "Voxel Process Gating"
		parent.add_child(title)
		title.owner = _hud.owner
	_create_dynamic_toggle(parent, "voxel_process_gating_enabled", "Enable Voxel Gating")
	_create_dynamic_toggle(parent, "voxel_dynamic_tick_rate_enabled", "Dynamic Tick Rate")
	_create_dynamic_toggle(parent, "smell_gpu_compute_enabled", "Smell GPU Compute")
	_create_dynamic_toggle(parent, "wind_gpu_compute_enabled", "Wind GPU Compute")
	_create_dynamic_toggle(parent, "smell_query_acceleration_enabled", "Accelerate Mammal Smell Queries")
	_create_dynamic_toggle(parent, "voxel_gate_smell_enabled", "Gate Smell by Voxel")
	_create_dynamic_toggle(parent, "voxel_gate_plants_enabled", "Gate Plants by Voxel")
	_create_dynamic_toggle(parent, "voxel_gate_mammals_enabled", "Gate Mammals by Voxel")
	_create_dynamic_toggle(parent, "voxel_gate_shelter_enabled", "Gate Shelter by Voxel")
	_create_dynamic_toggle(parent, "voxel_gate_profile_refresh_enabled", "Gate Profile Refresh by Voxel")
	_create_dynamic_toggle(parent, "voxel_gate_edible_index_enabled", "Gate Edible Index by Voxel")
	_create_dynamic_pair(parent, "voxel_tick_min_interval_seconds", "Voxel Tick Min (s)", 0.01, 1.2, 0.01, false)
	_create_dynamic_pair(parent, "voxel_tick_max_interval_seconds", "Voxel Tick Max (s)", 0.02, 3.0, 0.01, false)
	_create_dynamic_pair(parent, "voxel_smell_step_radius_cells", "Smell Local Radius", 1.0, 4.0, 1.0, true)
	_create_dynamic_pair(parent, "smell_query_top_k_per_layer", "Smell Candidate Top-K", 8.0, 256.0, 1.0, true)
	_create_dynamic_pair(parent, "smell_query_update_interval_seconds", "Smell Cache Update (s)", 0.01, 2.0, 0.01, false)

func _ensure_simulation_locality_controls(parent: VBoxContainer) -> void:
	if parent == null:
		return
	var title = parent.get_node_or_null("SimulationLocalityTitle") as Label
	if title == null:
		title = Label.new()
		title.name = "SimulationLocalityTitle"
		title.text = "Simulation Locality"
		parent.add_child(title)
		title.owner = _hud.owner
	_create_dynamic_toggle(parent, "simulation_locality_enabled", "Enable Regional Locality")
	_create_dynamic_toggle(parent, "simulation_locality_dynamic_enabled", "Dynamic Regional Tick Rate")
	_create_dynamic_pair(parent, "simulation_locality_radius_tiles", "Locality Radius (tiles)", 0.0, 6.0, 1.0, true)
	_create_dynamic_pair(parent, "pillar_height_scale", "Pillar Height", 0.25, 3.0, 0.05, false)
	_create_dynamic_pair(parent, "pillar_density_scale", "Pillar Density", 0.25, 3.0, 0.05, false)
	_create_dynamic_pair(parent, "wall_brittleness_scale", "Wall Brittleness", 0.1, 3.0, 0.05, false)

func _on_gpu_toggle_changed(_pressed: bool, option_id: String) -> void:
	if _graphics_ui_syncing:
		return
	var check = _toggle_controls.get(option_id, null) as CheckBox
	if check == null:
		return
	_emit_option(option_id, check.button_pressed)

func _on_dynamic_pair_changed(value: float, option_id: String, integer_mode: bool) -> void:
	if integer_mode:
		_sync_int_pair(value, option_id)
	else:
		_sync_float_pair_by_option(value, option_id)

func _create_dynamic_toggle(parent: VBoxContainer, option_id: String, label_text: String) -> void:
	var node_name = "DynToggle_%s" % option_id
	var check = parent.get_node_or_null(node_name) as CheckBox
	if check == null:
		check = CheckBox.new()
		check.name = node_name
		check.text = label_text
		check.toggled.connect(_on_gpu_toggle_changed.bind(option_id))
		parent.add_child(check)
		check.owner = _hud.owner
	_toggle_controls[option_id] = check

func _create_dynamic_pair(parent: VBoxContainer, option_id: String, label_text: String, min_value: float, max_value: float, step: float, integer_mode: bool) -> void:
	var row_name = "DynPair_%s" % option_id
	var row = parent.get_node_or_null(row_name) as HBoxContainer
	if row == null:
		row = HBoxContainer.new()
		row.name = row_name
		row.add_theme_constant_override("separation", 8)
		var label := Label.new()
		label.text = label_text
		label.custom_minimum_size = Vector2(180.0, 0.0)
		row.add_child(label)
		var slider := HSlider.new()
		slider.custom_minimum_size = Vector2(160.0, 0.0)
		slider.min_value = min_value
		slider.max_value = max_value
		slider.step = step
		row.add_child(slider)
		var spin := SpinBox.new()
		spin.min_value = min_value
		spin.max_value = max_value
		spin.step = step
		spin.custom_minimum_size = Vector2(96.0, 0.0)
		row.add_child(spin)
		slider.value_changed.connect(_on_dynamic_pair_changed.bind(option_id, integer_mode))
		spin.value_changed.connect(_on_dynamic_pair_changed.bind(option_id, integer_mode))
		parent.add_child(row)
		row.owner = _hud.owner
		label.owner = _hud.owner
		slider.owner = _hud.owner
		spin.owner = _hud.owner
	var nodes := row.get_children()
	if nodes.size() < 3:
		return
	var slider_node = nodes[1] as HSlider
	var spin_node = nodes[2] as SpinBox
	if slider_node != null and spin_node != null:
		_pair_controls[option_id] = _pair(slider_node, spin_node)

func _on_frame_graph_checkbox_toggled(_pressed: bool, option_id: String) -> void:
	on_frame_graph_toggle_changed(option_id)

func _apply_frame_graph_visibility(state: Dictionary) -> void:
	for row in FRAME_GRAPH_TOGGLE_ROWS:
		var option_key := String(row.get("key", ""))
		var series_key := String(row.get("series", ""))
		if option_key == "" or series_key == "" or not state.has(option_key):
			continue
		if _set_frame_series_visible.is_valid():
			_set_frame_series_visible.call(series_key, bool(state.get(option_key, true)))

func _apply_cloud_quality(state: Dictionary) -> void:
	if _cloud_quality_option == null:
		return
	var quality := String(state.get("cloud_quality", "low")).to_lower().strip_edges()
	var idx := 0
	match quality:
		"medium":
			idx = 1
		"high":
			idx = 2
		"ultra":
			idx = 3
	_cloud_quality_option.select(idx)

func _set_cloud_density(value: float) -> void:
	var clamped := clampf(value, 0.2, 2.0)
	if _cloud_density_slider != null:
		_cloud_density_slider.value = clamped
	if _cloud_density_spin != null:
		_cloud_density_spin.value = clamped

func _set_rain_visual(value: float) -> void:
	var clamped := clampf(value, 0.1, 1.5)
	if _rain_visual_slider != null:
		_rain_visual_slider.value = clamped
	if _rain_visual_spin != null:
		_rain_visual_spin.value = clamped

func _set_pair_value(option_id: String, value: float) -> void:
	var pair: Dictionary = _pair_controls.get(option_id, {})
	var slider: HSlider = pair.get("slider", null)
	var spin: SpinBox = pair.get("spin", null)
	if slider != null:
		slider.value = value
	if spin != null:
		spin.value = value

func _sync_int_pair(value: float, option_id: String) -> void:
	if _graphics_ui_syncing:
		return
	var ivalue := int(round(value))
	_set_pair_with_sync(option_id, ivalue)
	_emit_option(option_id, ivalue)

func _sync_float_pair_by_option(value: float, option_id: String) -> void:
	if _graphics_ui_syncing:
		return
	_set_pair_with_sync(option_id, value)
	_emit_option(option_id, value)

func _sync_float_pair(value: float, slider: HSlider, spin: SpinBox, option_id: String) -> void:
	if _graphics_ui_syncing:
		return
	_graphics_ui_syncing = true
	if slider != null:
		slider.value = value
	if spin != null:
		spin.value = value
	_graphics_ui_syncing = false
	_emit_option(option_id, value)

func _set_pair_with_sync(option_id: String, value) -> void:
	_graphics_ui_syncing = true
	_set_pair_value(option_id, float(value))
	_graphics_ui_syncing = false

func _emit_toggle(option_id: String, checkbox: CheckBox) -> void:
	if checkbox == null:
		return
	_emit_option(option_id, checkbox.button_pressed)

func _emit_option(option_id: String, value) -> void:
	if _emit_graphics_option_changed.is_valid():
		_emit_graphics_option_changed.call(option_id, value)

func _pair(slider: HSlider, spin: SpinBox) -> Dictionary:
	return {"slider": slider, "spin": spin}
