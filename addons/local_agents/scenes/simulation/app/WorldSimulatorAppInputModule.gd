extends "res://addons/local_agents/scenes/simulation/app/WorldSimulatorAppRenderModule.gd"

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event = event as InputEventKey
		if key_event.pressed and not key_event.echo and key_event.keycode == KEY_F3:
			_set_debug_column_visible(not _debug_column_visible)
			get_viewport().set_input_as_handled()
			return
		if key_event.pressed and not key_event.echo and key_event.keycode == KEY_F4:
			_set_debug_compact_mode(not _debug_compact_mode)
			get_viewport().set_input_as_handled()
			return
		if key_event.pressed and not key_event.echo and key_event.keycode == KEY_V:
			_manual_vent_place_mode = not _manual_vent_place_mode
			if _manual_place_vent_button != null and is_instance_valid(_manual_place_vent_button):
				_manual_place_vent_button.button_pressed = _manual_vent_place_mode
			_refresh_manual_vent_status()
			get_viewport().set_input_as_handled()
			return
		if key_event.pressed and not key_event.echo and key_event.keycode == KEY_B:
			_manual_eruption_active = not _manual_eruption_active
			if _manual_erupt_button != null and is_instance_valid(_manual_erupt_button):
				_manual_erupt_button.button_pressed = _manual_eruption_active
			_refresh_manual_vent_status()
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseButton:
		var mouse_button = event as InputEventMouseButton
		if mouse_button.pressed and mouse_button.button_index == MOUSE_BUTTON_LEFT and _manual_vent_place_mode:
			var tile = _tile_from_screen_position(mouse_button.position)
			if tile.x >= 0 and tile.y >= 0:
				_spawn_manual_vent_at(tile.x, tile.y)
				_manual_vent_place_mode = false
				if _manual_place_vent_button != null and is_instance_valid(_manual_place_vent_button):
					_manual_place_vent_button.button_pressed = false
				_refresh_manual_vent_status()
			get_viewport().set_input_as_handled()
			return
		if mouse_button.pressed and mouse_button.button_index == MOUSE_BUTTON_LEFT and not _manual_vent_place_mode:
			var inspect_tile = _tile_from_screen_position(mouse_button.position)
			if inspect_tile.x >= 0 and inspect_tile.y >= 0:
				_inspect_feature_at_tile(inspect_tile.x, inspect_tile.y)
			get_viewport().set_input_as_handled()
			return
	if _interaction_controller.handle_camera_input(event):
		get_viewport().set_input_as_handled()


func _refresh_manual_vent_status() -> void:
	if _manual_vent_status_label == null or not is_instance_valid(_manual_vent_status_label):
		return
	var vent_text = _manual_selected_vent_tile_id if _manual_selected_vent_tile_id != "" else "none"
	var mode = "idle"
	if _manual_vent_place_mode:
		mode = "placing"
	elif _manual_eruption_active:
		mode = "erupting"
	var vent_info = _feature_query.find_volcano_by_tile_id(_world_snapshot, _manual_selected_vent_tile_id)
	if not vent_info.is_empty():
		_manual_vent_status_label.text = "Vent: %s | Mode: %s | activity %.2f | radius %d" % [
			vent_text,
			mode,
			clampf(float(vent_info.get("activity", 0.0)), 0.0, 1.0),
			int(vent_info.get("radius", 0)),
		]
	else:
		_manual_vent_status_label.text = "Vent: %s | Mode: %s" % [vent_text, mode]
	_refresh_feature_inspect_text()
	_update_feature_select_marker()

func _tile_from_screen_position(screen_pos: Vector2) -> Vector2i:
	return _interaction_controller.tile_from_screen_position(_camera, _world_snapshot, screen_pos)

func _spawn_manual_vent_at(tx: int, tz: int) -> void:
	if _world_snapshot.is_empty():
		return
	var island_growth = maxf(0.0, float(_island_growth_spin.value)) if _island_growth_spin != null else island_growth_per_eruption
	var spawned = _volcanic.spawn_manual_vent_at(_world_snapshot, tx, tz, _sim_tick, island_growth)
	_world_snapshot = spawned.get("world", _world_snapshot)
	var tile_id = String(spawned.get("selected_tile_id", ""))
	if tile_id != "":
		_manual_selected_vent_tile_id = tile_id
		_local_activity_by_tile[tile_id] = 1.0
	var feature = spawned.get("feature", {})
	if feature is Dictionary and tile_id != "":
		_selected_feature = {"kind": "vent", "tile_id": tile_id, "data": (feature as Dictionary).duplicate(true)}
	_refresh_manual_vent_status()

func _inspect_feature_at_tile(tx: int, tz: int) -> void:
	var tile_id = TileKeyUtilsScript.tile_id(tx, tz)
	var vent = _feature_query.find_volcano_by_tile_id(_world_snapshot, tile_id)
	if vent.is_empty():
		vent = _feature_query.find_volcano_covering_tile(_world_snapshot, tx, tz)
	if not vent.is_empty():
		_manual_selected_vent_tile_id = String(vent.get("tile_id", tile_id))
		_selected_feature = {
			"kind": "vent",
			"tile_id": _manual_selected_vent_tile_id,
			"data": vent.duplicate(true),
		}
		_refresh_manual_vent_status()
		return
	var spring = _feature_query.find_spring_by_tile_id(_world_snapshot, tile_id)
	if not spring.is_empty():
		_selected_feature = {
			"kind": "spring",
			"tile_id": tile_id,
			"data": spring.duplicate(true),
		}
		_refresh_manual_vent_status()
		return
	_selected_feature = {
		"kind": "tile",
		"tile_id": tile_id,
		"data": {},
	}
	_refresh_manual_vent_status()

func _refresh_feature_inspect_text() -> void:
	if _feature_inspect_label == null or not is_instance_valid(_feature_inspect_label):
		return
	_feature_inspect_label.text = _feature_query.build_inspect_text(_selected_feature)

func _ensure_feature_select_marker() -> void:
	_feature_select_marker = _feature_marker_renderer.ensure_marker(self, _feature_select_marker)

func _update_feature_select_marker() -> void:
	if _feature_select_marker == null or not is_instance_valid(_feature_select_marker):
		return
	if _selected_feature.is_empty():
		_feature_marker_renderer.update_marker(_feature_select_marker, 0, 0, 0.0, false)
		return
	var tile_id = String(_selected_feature.get("tile_id", ""))
	if tile_id == "":
		_feature_marker_renderer.update_marker(_feature_select_marker, 0, 0, 0.0, false)
		return
	var coords = TileKeyUtilsScript.parse_tile_id(tile_id)
	if coords.x == 2147483647:
		_feature_marker_renderer.update_marker(_feature_select_marker, 0, 0, 0.0, false)
		return
	var y = _surface_height_for_tile(tile_id) + 0.25
	_feature_marker_renderer.update_marker(_feature_select_marker, coords.x, coords.y, y, true)

