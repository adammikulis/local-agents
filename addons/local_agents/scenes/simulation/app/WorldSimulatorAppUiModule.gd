extends "res://addons/local_agents/scenes/simulation/app/WorldSimulatorAppInputModule.gd"

func _on_graphics_button_pressed() -> void:
	_set_graphics_options_expanded(_graphics_button.button_pressed)

func _set_graphics_options_expanded(expanded: bool) -> void:
	_graphics_options_expanded = expanded
	if _graphics_button != null:
		_graphics_button.button_pressed = expanded
		_graphics_button.text = "Graphics ▾" if expanded else "Graphics ▸"
	var graphics_nodes = [
		get_node_or_null("CanvasLayer/PanelContainer/MarginContainer/RootVBox/QualityRow"),
		get_node_or_null("CanvasLayer/PanelContainer/MarginContainer/RootVBox/EnvironmentRow"),
		get_node_or_null("CanvasLayer/PanelContainer/MarginContainer/RootVBox/LightningRow"),
		get_node_or_null("CanvasLayer/PanelContainer/MarginContainer/RootVBox/EruptionRow"),
		get_node_or_null("CanvasLayer/PanelContainer/MarginContainer/RootVBox/TideGrid"),
		get_node_or_null("CanvasLayer/PanelContainer/MarginContainer/RootVBox/PerfGrid"),
		get_node_or_null("CanvasLayer/PanelContainer/MarginContainer/RootVBox/WaterShaderGrid"),
	]
	for node_variant in graphics_nodes:
		if node_variant is CanvasItem:
			(node_variant as CanvasItem).visible = expanded


func _setup_debug_column_ui() -> void:
	if _ui_canvas == null or _stats_label == null or _perf_compare_label == null:
		return
	if _debug_column_panel != null and is_instance_valid(_debug_column_panel):
		return
	_debug_column_toggle = Button.new()
	_debug_column_toggle.text = "Debug ▾"
	_debug_column_toggle.anchor_left = 1.0
	_debug_column_toggle.anchor_right = 1.0
	_debug_column_toggle.anchor_top = 0.0
	_debug_column_toggle.anchor_bottom = 0.0
	_debug_column_toggle.offset_left = -118.0
	_debug_column_toggle.offset_top = 12.0
	_debug_column_toggle.offset_right = -12.0
	_debug_column_toggle.offset_bottom = 38.0
	_debug_column_toggle.focus_mode = Control.FOCUS_NONE
	_debug_column_toggle.pressed.connect(func():
		_set_debug_column_visible(not _debug_column_visible)
	)
	_ui_canvas.add_child(_debug_column_toggle)

	_debug_compact_toggle = Button.new()
	_debug_compact_toggle.text = "Compact Off"
	_debug_compact_toggle.anchor_left = 1.0
	_debug_compact_toggle.anchor_right = 1.0
	_debug_compact_toggle.anchor_top = 0.0
	_debug_compact_toggle.anchor_bottom = 0.0
	_debug_compact_toggle.offset_left = -242.0
	_debug_compact_toggle.offset_top = 12.0
	_debug_compact_toggle.offset_right = -122.0
	_debug_compact_toggle.offset_bottom = 38.0
	_debug_compact_toggle.focus_mode = Control.FOCUS_NONE
	_debug_compact_toggle.pressed.connect(func():
		_set_debug_compact_mode(not _debug_compact_mode)
	)
	_ui_canvas.add_child(_debug_compact_toggle)

	_debug_column_panel = PanelContainer.new()
	_debug_column_panel.anchor_left = 1.0
	_debug_column_panel.anchor_right = 1.0
	_debug_column_panel.anchor_top = 0.0
	_debug_column_panel.anchor_bottom = 0.0
	_debug_column_panel.offset_left = -372.0
	_debug_column_panel.offset_top = 44.0
	_debug_column_panel.offset_right = -12.0
	_debug_column_panel.offset_bottom = 280.0
	_debug_column_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_ui_canvas.add_child(_debug_column_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_debug_column_panel.add_child(margin)

	_debug_column_body = VBoxContainer.new()
	_debug_column_body.add_theme_constant_override("separation", 4)
	margin.add_child(_debug_column_body)

	if _stats_label.get_parent() != null:
		_stats_label.get_parent().remove_child(_stats_label)
	_debug_column_body.add_child(_stats_label)
	_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stats_label.add_theme_font_size_override("font_size", 11)

	if _perf_compare_label.get_parent() != null:
		_perf_compare_label.get_parent().remove_child(_perf_compare_label)
	_debug_column_body.add_child(_perf_compare_label)
	_perf_compare_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_perf_compare_label.add_theme_font_size_override("font_size", 11)
	_apply_debug_column_layout()
	_set_debug_column_visible(true)


func _set_debug_column_visible(visible: bool) -> void:
	_debug_column_visible = visible
	if _debug_column_panel != null and is_instance_valid(_debug_column_panel):
		_debug_column_panel.visible = visible
	if _debug_column_toggle != null and is_instance_valid(_debug_column_toggle):
		_debug_column_toggle.text = "Debug ▾" if visible else "Debug ▸"
	if _debug_compact_toggle != null and is_instance_valid(_debug_compact_toggle):
		_debug_compact_toggle.visible = visible


func _setup_manual_eruption_controls() -> void:
	if _ui_canvas == null:
		return
	if _rts_bottom_panel != null and is_instance_valid(_rts_bottom_panel):
		return
	_rts_bottom_panel = PanelContainer.new()
	_rts_bottom_panel.anchor_left = 0.0
	_rts_bottom_panel.anchor_right = 1.0
	_rts_bottom_panel.anchor_top = 1.0
	_rts_bottom_panel.anchor_bottom = 1.0
	_rts_bottom_panel.offset_left = 10.0
	_rts_bottom_panel.offset_top = -146.0
	_rts_bottom_panel.offset_right = -10.0
	_rts_bottom_panel.offset_bottom = -10.0
	_rts_bottom_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_ui_canvas.add_child(_rts_bottom_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_rts_bottom_panel.add_child(margin)

	_rts_tabs = TabContainer.new()
	_rts_tabs.tab_alignment = TabBar.ALIGNMENT_LEFT
	margin.add_child(_rts_tabs)

	var geology_tab := VBoxContainer.new()
	geology_tab.name = "Geology"
	geology_tab.add_theme_constant_override("separation", 6)
	_rts_tabs.add_child(geology_tab)

	var vent_row := HBoxContainer.new()
	vent_row.add_theme_constant_override("separation", 8)
	geology_tab.add_child(vent_row)

	_manual_place_vent_button = Button.new()
	_manual_place_vent_button.text = "Place Vent (V)"
	_manual_place_vent_button.toggle_mode = true
	_manual_place_vent_button.toggled.connect(func(enabled: bool):
		_manual_vent_place_mode = enabled
		_refresh_manual_vent_status()
	)
	vent_row.add_child(_manual_place_vent_button)

	_manual_erupt_button = Button.new()
	_manual_erupt_button.text = "Erupt Hold (B)"
	_manual_erupt_button.toggle_mode = true
	_manual_erupt_button.toggled.connect(func(enabled: bool):
		_manual_eruption_active = enabled
		_refresh_manual_vent_status()
	)
	vent_row.add_child(_manual_erupt_button)

	var stop_button := Button.new()
	stop_button.text = "Stop"
	stop_button.pressed.connect(func():
		_manual_vent_place_mode = false
		_manual_eruption_active = false
		if _manual_place_vent_button != null and is_instance_valid(_manual_place_vent_button):
			_manual_place_vent_button.button_pressed = false
		if _manual_erupt_button != null and is_instance_valid(_manual_erupt_button):
			_manual_erupt_button.button_pressed = false
		_refresh_manual_vent_status()
	)
	vent_row.add_child(stop_button)

	_manual_vent_status_label = Label.new()
	_manual_vent_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_manual_vent_status_label.text = "Vent: none | Mode: idle"
	geology_tab.add_child(_manual_vent_status_label)

	_feature_inspect_label = Label.new()
	_feature_inspect_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_feature_inspect_label.text = "Inspect: click terrain to select vent/spring."
	geology_tab.add_child(_feature_inspect_label)

	var eruption_hint := Label.new()
	eruption_hint.text = "LMB terrain while Place Vent is active to add/select vent."
	geology_tab.add_child(eruption_hint)

	var simulation_tab := VBoxContainer.new()
	simulation_tab.name = "Simulation"
	var sim_label := Label.new()
	sim_label.text = "Time controls in HUD. Backend/quality on left panel."
	simulation_tab.add_child(sim_label)
	_rts_tabs.add_child(simulation_tab)

	var events_tab := VBoxContainer.new()
	events_tab.name = "Events"
	events_tab.add_theme_constant_override("separation", 6)
	var events_row := HBoxContainer.new()
	events_row.add_theme_constant_override("separation", 8)
	events_tab.add_child(events_row)
	var lightning_button := Button.new()
	lightning_button.text = "Lightning Strike"
	lightning_button.pressed.connect(_on_lightning_strike_pressed)
	events_row.add_child(lightning_button)
	var vent_random_button := Button.new()
	vent_random_button.text = "Spawn Random Vent"
	vent_random_button.pressed.connect(func():
		var spawned = _volcanic.try_spawn_new_vent(_world_snapshot, _sim_tick)
		_world_snapshot = spawned.get("world", _world_snapshot)
		_refresh_manual_vent_status()
	)
	events_row.add_child(vent_random_button)
	var events_hint := Label.new()
	events_hint.text = "Manual world events are centralized here."
	events_tab.add_child(events_hint)
	_rts_tabs.add_child(events_tab)

	var camera_tab := VBoxContainer.new()
	camera_tab.name = "Camera"
	var cam_label := Label.new()
	cam_label.text = "RMB orbit | MMB pan | Wheel zoom | WASD/QE move"
	camera_tab.add_child(cam_label)
	_rts_tabs.add_child(camera_tab)

	_refresh_manual_vent_status()
	_ensure_feature_select_marker()


func _set_debug_compact_mode(compact: bool) -> void:
	_debug_compact_mode = compact
	if _debug_compact_toggle != null and is_instance_valid(_debug_compact_toggle):
		_debug_compact_toggle.text = "Compact On" if compact else "Compact Off"
	_apply_debug_column_layout()

func _apply_debug_column_layout() -> void:
	if _debug_column_panel == null or not is_instance_valid(_debug_column_panel):
		return
	var panel_width = 252.0 if _debug_compact_mode else 360.0
	_debug_column_panel.offset_left = -12.0 - panel_width
	_debug_column_panel.offset_right = -12.0
	_debug_column_panel.offset_bottom = 210.0 if _debug_compact_mode else 280.0
	if _stats_label != null:
		_stats_label.add_theme_font_size_override("font_size", 10 if _debug_compact_mode else 11)
	if _perf_compare_label != null:
		_perf_compare_label.add_theme_font_size_override("font_size", 10 if _debug_compact_mode else 11)


func _update_stats(world: Dictionary, hydrology: Dictionary, seed: int) -> void:
	var voxel_world: Dictionary = world.get("voxel_world", {})
	var block_counts: Dictionary = voxel_world.get("block_type_counts", {})
	var water_tiles: Dictionary = hydrology.get("water_tiles", {})
	var flow_map: Dictionary = world.get("flow_map", {})
	var max_flow = float(flow_map.get("max_flow", 0.0))
	var avg_rain = float(_weather_snapshot.get("avg_rain_intensity", 0.0))
	var avg_fog = float(_weather_snapshot.get("avg_fog_intensity", 0.0))
	var avg_sun = float(_solar_snapshot.get("avg_insolation", 0.0))
	var avg_uv = float(_solar_snapshot.get("avg_uv_index", 0.0))
	var geology: Dictionary = world.get("geology", {})
	var volcanoes = int((geology.get("volcanic_features", []) as Array).size())
	var springs: Dictionary = world.get("springs", {})
	var spring_count = int((springs.get("all", []) as Array).size())
	var year = _year_at_tick(_sim_tick)
	if _debug_compact_mode:
		_stats_label.text = "seed %d | %s\nblk %d water %d flow %.2f\nrain %.2f fog %.2f sun %.2f uv %.2f\nvolc %d spring %d slide %d\nyear %.1f t+%s" % [
			seed,
			_sim_backend_mode,
			int((voxel_world.get("block_rows", []) as Array).size()),
			int(water_tiles.size()),
			max_flow,
			avg_rain,
			avg_fog,
			avg_sun,
			avg_uv,
			volcanoes,
			spring_count,
			_landslide_count,
			year,
			_format_duration_hms(_simulated_seconds),
		]
	else:
		_stats_label.text = "seed=%d | mode=%s | blocks=%d | water_tiles=%d | max_flow=%0.2f | rain=%0.2f | fog=%0.2f | sun=%0.2f | uv=%0.2f | volcanoes=%d | springs=%d | slides=%d | tod=%0.2f | year=%0.1f | sim_t=%s" % [
			seed,
			_sim_backend_mode,
			int((voxel_world.get("block_rows", []) as Array).size()),
			int(water_tiles.size()),
			max_flow,
			avg_rain,
			avg_fog,
			avg_sun,
			avg_uv,
			volcanoes,
			spring_count,
			_landslide_count,
			_time_of_day,
			year,
			_format_duration_hms(_simulated_seconds),
		]

