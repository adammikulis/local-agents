extends RefCounted
class_name AtmosphereSystemAdapter

func _texture_budget_for_controller(controller: Node, expected_cells: int) -> int:
	var budget = int(controller.field_texture_update_budget_cells)
	if controller.has_method("get_effective_texture_budget_cells"):
		budget = int(controller.call("get_effective_texture_budget_cells"))
	return mini(maxi(512, budget), expected_cells)

func ensure_volumetric_cloud_shell(controller: Node) -> void:
	if not controller.clouds_enabled:
		if controller._cloud_renderer != null:
			controller._cloud_renderer.clear_generated()
		return
	controller._ensure_renderer_nodes()
	controller._cloud_renderer.ensure_layers()
	update_volumetric_cloud_geometry(controller)

func update_volumetric_cloud_geometry(controller: Node) -> void:
	if not controller.clouds_enabled:
		return
	controller._ensure_renderer_nodes()
	controller._cloud_renderer.update_geometry(controller._generation_snapshot)

func update_volumetric_cloud_weather(controller: Node, rain: float, cloud: float, humidity: float, wind: Vector2, wind_speed: float) -> void:
	update_cloud_layer_weather(controller, rain, cloud, humidity, wind, wind_speed)

func ensure_cloud_layer(controller: Node) -> void:
	if not controller.clouds_enabled:
		if controller._cloud_renderer != null:
			controller._cloud_renderer.clear_generated()
		return
	controller._ensure_renderer_nodes()
	controller._cloud_renderer.ensure_layers()

func update_cloud_layer_geometry(controller: Node) -> void:
	if not controller.clouds_enabled:
		return
	controller._ensure_renderer_nodes()
	controller._cloud_renderer.update_geometry(controller._generation_snapshot)

func update_cloud_layer_weather(controller: Node, rain: float, cloud: float, humidity: float, wind: Vector2, wind_speed: float) -> void:
	if not controller.clouds_enabled:
		return
	controller._ensure_renderer_nodes()
	apply_cloud_quality_settings(controller)
	controller._cloud_renderer.update_weather(
		rain,
		cloud,
		humidity,
		wind,
		wind_speed,
		controller._weather_field_texture,
		controller._weather_field_world_size,
		controller._lightning_flash
	)

func set_cloud_quality_settings(controller: Node, tier: String, slice_density: float) -> void:
	controller.cloud_quality_tier = String(tier).to_lower().strip_edges()
	controller.cloud_slice_density = clampf(slice_density, 0.25, 3.0)
	controller.cloud_density_scale = controller.cloud_slice_density
	apply_cloud_quality_settings(controller)

func apply_cloud_quality_settings(controller: Node) -> void:
	if controller._cloud_renderer == null:
		return
	if controller._cloud_renderer.has_method("set_quality_tier"):
		controller._cloud_renderer.call("set_quality_tier", controller.cloud_quality_tier)
	if controller._cloud_renderer.has_method("set_slice_density"):
		controller._cloud_renderer.call("set_slice_density", controller.cloud_density_scale)

func ensure_weather_field_texture(controller: Node) -> void:
	var width = maxi(1, int(controller._generation_snapshot.get("width", 1)))
	var height = maxi(1, int(controller._generation_snapshot.get("height", 1)))
	var needs_recreate = (
		controller._weather_field_image == null
		or controller._weather_field_texture == null
		or controller._weather_field_image.get_width() != width
		or controller._weather_field_image.get_height() != height
	)
	controller._weather_field_world_size = Vector2(float(width), float(height))
	if not needs_recreate:
		return
	controller._weather_field_image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	controller._weather_field_image.fill(Color(0.0, 0.0, 0.0, 1.0))
	controller._weather_field_texture = ImageTexture.create_from_image(controller._weather_field_image)
	controller._weather_field_cache.resize(width * height)
	for i in range(controller._weather_field_cache.size()):
		controller._weather_field_cache[i] = -1
	controller._weather_field_last_avg_pack = -1

func ensure_surface_field_texture(controller: Node) -> void:
	var width = maxi(1, int(controller._generation_snapshot.get("width", 1)))
	var height = maxi(1, int(controller._generation_snapshot.get("height", 1)))
	var needs_recreate = (
		controller._surface_field_image == null
		or controller._surface_field_texture == null
		or controller._surface_field_image.get_width() != width
		or controller._surface_field_image.get_height() != height
	)
	if not needs_recreate:
		return
	controller._surface_field_image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	controller._surface_field_image.fill(Color(0.0, 0.0, 0.0, 1.0))
	controller._surface_field_texture = ImageTexture.create_from_image(controller._surface_field_image)
	controller._surface_field_cache.resize(width * height)
	for i in range(controller._surface_field_cache.size()):
		controller._surface_field_cache[i] = -1
	controller._tile_temperature_map.resize(width * height)
	controller._tile_flow_map.resize(width * height)
	for i in range(width * height):
		controller._tile_temperature_map[i] = 0.5
		controller._tile_flow_map[i] = 0.0
	controller._surface_field_last_update_tick = -1

func ensure_solar_field_texture(controller: Node) -> void:
	var width = maxi(1, int(controller._generation_snapshot.get("width", 1)))
	var height = maxi(1, int(controller._generation_snapshot.get("height", 1)))
	var needs_recreate = (
		controller._solar_field_image == null
		or controller._solar_field_texture == null
		or controller._solar_field_image.get_width() != width
		or controller._solar_field_image.get_height() != height
	)
	if not needs_recreate:
		return
	controller._solar_field_image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	controller._solar_field_image.fill(Color(0.0, 0.0, 0.0, 1.0))
	controller._solar_field_texture = ImageTexture.create_from_image(controller._solar_field_image)
	controller._solar_field_cache.resize(width * height)
	for i in range(controller._solar_field_cache.size()):
		controller._solar_field_cache[i] = -1
	controller._solar_field_last_tick = -1

func refresh_surface_state_from_generation(controller: Node) -> void:
	ensure_surface_field_texture(controller)
	if controller._surface_field_image == null:
		return
	var width = controller._surface_field_image.get_width()
	var height = controller._surface_field_image.get_height()
	var tile_index: Dictionary = controller._generation_snapshot.get("tile_index", {})
	var flow_rows_by_tile: Dictionary = {}
	var flow_rows: Array = (controller._generation_snapshot.get("flow_map", {}) as Dictionary).get("rows", [])
	for row_variant in flow_rows:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var tile_id = "%d:%d" % [int(row.get("x", 0)), int(row.get("y", 0))]
		flow_rows_by_tile[tile_id] = clampf(float(row.get("channel_strength", 0.0)), 0.0, 1.0)
	for y in range(height):
		for x in range(width):
			var idx = y * width + x
			var tile_id = "%d:%d" % [x, y]
			var tile = tile_index.get(tile_id, {})
			var temp = clampf(float((tile as Dictionary).get("temperature", 0.5)) if tile is Dictionary else 0.5, 0.0, 1.0)
			var flow = clampf(float(flow_rows_by_tile.get(tile_id, 0.0)), 0.0, 1.0)
			controller._tile_temperature_map[idx] = temp
			controller._tile_flow_map[idx] = flow
			var snow = clampf((0.34 - temp) * 2.2, 0.0, 1.0)
			var c = Color(0.0, snow, flow, 0.0)
			var pack = pack_weather_color(c)
			controller._surface_field_cache[idx] = pack
			controller._surface_field_image.set_pixel(x, y, c)
	controller._surface_field_texture.update(controller._surface_field_image)

func update_surface_state_texture(controller: Node, weather_snapshot: Dictionary) -> void:
	ensure_surface_field_texture(controller)
	if controller._surface_field_image == null or controller._surface_field_texture == null:
		return
	var tick = int(weather_snapshot.get("tick", -1))
	if tick >= 0 and (tick % maxi(1, controller.surface_texture_update_interval_ticks)) != 0:
		return
	if tick == controller._surface_field_last_update_tick:
		return
	controller._surface_field_last_update_tick = tick
	var width = controller._surface_field_image.get_width()
	var height = controller._surface_field_image.get_height()
	var rows: Array = weather_snapshot.get("rows", [])
	var buffers: Dictionary = weather_snapshot.get("buffers", {})
	var weather_rain: PackedFloat32Array = buffers.get("rain", PackedFloat32Array())
	var weather_humidity: PackedFloat32Array = buffers.get("humidity", PackedFloat32Array())
	var use_buffers = weather_rain.size() == width * height and weather_humidity.size() == width * height
	var by_tile: Dictionary = {}
	if not use_buffers:
		for row_variant in rows:
			if row_variant is Dictionary:
				var row = row_variant as Dictionary
				by_tile["%d:%d" % [int(row.get("x", 0)), int(row.get("y", 0))]] = row
	var avg_rain = clampf(float(weather_snapshot.get("avg_rain_intensity", 0.0)), 0.0, 1.0)
	var avg_humidity = clampf(float(weather_snapshot.get("avg_humidity", 0.0)), 0.0, 1.0)
	var dirty = 0
	var expected = width * height
	var budget = _texture_budget_for_controller(controller, expected)
	var start = clampi(controller._surface_field_update_cursor, 0, maxi(0, expected - 1))
	for offset in range(budget):
		var idx = (start + offset) % expected
		var x = idx % width
		var y = idx / width
		var prev = controller._surface_field_image.get_pixel(x, y)
		var rain = avg_rain
		var humidity = avg_humidity
		if use_buffers:
			rain = clampf(float(weather_rain[idx]), 0.0, 1.0)
			humidity = clampf(float(weather_humidity[idx]), 0.0, 1.0)
		else:
			var row = by_tile.get("%d:%d" % [x, y], {})
			rain = clampf(float((row as Dictionary).get("rain", avg_rain)) if row is Dictionary else avg_rain, 0.0, 1.0)
			humidity = clampf(float((row as Dictionary).get("humidity", avg_humidity)) if row is Dictionary else avg_humidity, 0.0, 1.0)
		var temp = controller._tile_temperature_map[idx] if idx < controller._tile_temperature_map.size() else 0.5
		var flow = controller._tile_flow_map[idx] if idx < controller._tile_flow_map.size() else 0.0
		var wet = clampf(prev.r * 0.965 + rain * 0.09 + humidity * 0.012, 0.0, 1.0)
		var snow = prev.g
		if temp < 0.34:
			snow = clampf(snow * 0.995 + rain * (0.024 + (0.34 - temp) * 0.02), 0.0, 1.0)
		else:
			snow = clampf(snow - (0.008 + temp * 0.018 + wet * 0.01), 0.0, 1.0)
		var erosion = clampf(prev.a * 0.986 + rain * flow * 0.022 + wet * flow * 0.009, 0.0, 1.0)
		var next = Color(wet, snow, flow, erosion)
		var pack = pack_weather_color(next)
		if controller._surface_field_cache[idx] == pack:
			continue
		controller._surface_field_cache[idx] = pack
		controller._surface_field_image.set_pixel(x, y, next)
		dirty += 1
	controller._surface_field_update_cursor = (start + budget) % maxi(1, expected)
	if dirty > 0:
		controller._surface_field_texture.update(controller._surface_field_image)

func update_solar_field_texture(controller: Node, solar_snapshot: Dictionary) -> void:
	ensure_solar_field_texture(controller)
	if controller._solar_field_image == null or controller._solar_field_texture == null:
		return
	var tick = int(solar_snapshot.get("tick", -1))
	if tick >= 0 and (tick % maxi(1, controller.solar_texture_update_interval_ticks)) != 0:
		return
	if tick == controller._solar_field_last_tick:
		return
	controller._solar_field_last_tick = tick
	var width = controller._solar_field_image.get_width()
	var height = controller._solar_field_image.get_height()
	var avg_absorbed = clampf(float(solar_snapshot.get("avg_insolation", 0.0)), 0.0, 1.0)
	var avg_uv = clampf(float(solar_snapshot.get("avg_uv_index", 0.0)) / 2.0, 0.0, 1.0)
	var avg_heat = clampf(float(solar_snapshot.get("avg_heat_load", 0.0)) / 1.5, 0.0, 1.0)
	var avg_growth = clampf(float(solar_snapshot.get("avg_growth_factor", 0.0)), 0.0, 1.0)
	var buffers: Dictionary = solar_snapshot.get("buffers", {})
	var sunlight_buffer: PackedFloat32Array = buffers.get("sunlight_total", PackedFloat32Array())
	var uv_buffer: PackedFloat32Array = buffers.get("uv_index", PackedFloat32Array())
	var heat_buffer: PackedFloat32Array = buffers.get("heat_load", PackedFloat32Array())
	var growth_buffer: PackedFloat32Array = buffers.get("plant_growth_factor", PackedFloat32Array())
	var expected = width * height
	var use_buffers = (
		sunlight_buffer.size() == expected
		and uv_buffer.size() == expected
		and heat_buffer.size() == expected
		and growth_buffer.size() == expected
	)
	var rows: Array = solar_snapshot.get("rows", [])
	var dirty = 0
	if use_buffers:
		var budget = _texture_budget_for_controller(controller, expected)
		var start = clampi(controller._solar_field_update_cursor, 0, maxi(0, expected - 1))
		for offset in range(budget):
			var i = (start + offset) % expected
			var x = i % width
			var y = i / width
			var c = Color(
				clampf(float(sunlight_buffer[i]), 0.0, 1.0),
				clampf(float(uv_buffer[i]) / 2.0, 0.0, 1.0),
				clampf(float(heat_buffer[i]) / 1.5, 0.0, 1.0),
				clampf(float(growth_buffer[i]), 0.0, 1.0)
			)
			var pack = pack_weather_color(c)
			if controller._solar_field_cache[i] == pack:
				continue
			controller._solar_field_cache[i] = pack
			controller._solar_field_image.set_pixel(x, y, c)
			dirty += 1
		controller._solar_field_update_cursor = (start + budget) % maxi(1, expected)
	elif rows.size() < expected:
		var fill = Color(avg_absorbed, avg_uv, avg_heat, avg_growth)
		var fill_pack = pack_weather_color(fill)
		for i in range(controller._solar_field_cache.size()):
			if controller._solar_field_cache[i] == fill_pack:
				continue
			controller._solar_field_cache[i] = fill_pack
			var x = i % width
			var y = i / width
			controller._solar_field_image.set_pixel(x, y, fill)
			dirty += 1
	if not use_buffers:
		for row_variant in rows:
			if not (row_variant is Dictionary):
				continue
			var row = row_variant as Dictionary
			var tile_id = String(row.get("tile_id", ""))
			var parts = tile_id.split(":")
			if parts.size() != 2:
				continue
			var x = int(parts[0])
			var y = int(parts[1])
			if x < 0 or x >= width or y < 0 or y >= height:
				continue
			var c = Color(
				clampf(float(row.get("sunlight_absorbed", row.get("sunlight_total", 0.0))), 0.0, 1.5) / 1.5,
				clampf(float(row.get("uv_index", 0.0)), 0.0, 2.0) / 2.0,
				clampf(float(row.get("heat_load", 0.0)), 0.0, 1.5) / 1.5,
				clampf(float(row.get("plant_growth_factor", 0.0)), 0.0, 1.0)
			)
			var pack = pack_weather_color(c)
			var idx = y * width + x
			if idx < 0 or idx >= controller._solar_field_cache.size():
				continue
			if controller._solar_field_cache[idx] == pack:
				continue
			controller._solar_field_cache[idx] = pack
			controller._solar_field_image.set_pixel(x, y, c)
			dirty += 1
	if dirty > 0:
		controller._solar_field_texture.update(controller._solar_field_image)

func update_weather_field_texture(controller: Node, weather_snapshot: Dictionary) -> void:
	ensure_weather_field_texture(controller)
	if controller._weather_field_image == null or controller._weather_field_texture == null:
		return
	var tick = int(weather_snapshot.get("tick", -1))
	if tick >= 0 and (tick % maxi(1, controller.weather_texture_update_interval_ticks)) != 0:
		return
	var width = controller._weather_field_image.get_width()
	var height = controller._weather_field_image.get_height()
	var avg_cloud = clampf(float(weather_snapshot.get("avg_cloud_cover", 0.0)), 0.0, 1.0)
	var avg_rain = clampf(float(weather_snapshot.get("avg_rain_intensity", 0.0)), 0.0, 1.0)
	var avg_humidity = clampf(float(weather_snapshot.get("avg_humidity", 0.0)), 0.0, 1.0)
	var avg_fog = clampf(float(weather_snapshot.get("avg_fog_intensity", 0.0)), 0.0, 1.0)
	var fill_color = Color(avg_cloud, avg_rain, avg_humidity, avg_fog)
	var avg_pack = pack_weather_color(fill_color)
	var buffers: Dictionary = weather_snapshot.get("buffers", {})
	var cloud_buffer: PackedFloat32Array = buffers.get("cloud", PackedFloat32Array())
	var rain_buffer: PackedFloat32Array = buffers.get("rain", PackedFloat32Array())
	var humidity_buffer: PackedFloat32Array = buffers.get("humidity", PackedFloat32Array())
	var fog_buffer: PackedFloat32Array = buffers.get("fog", PackedFloat32Array())
	var use_buffers = (
		cloud_buffer.size() == width * height
		and rain_buffer.size() == width * height
		and humidity_buffer.size() == width * height
		and fog_buffer.size() == width * height
	)
	var rows: Array = weather_snapshot.get("rows", [])
	var expected_cells = width * height
	var dirty_count = 0
	if use_buffers:
		var budget = _texture_budget_for_controller(controller, expected_cells)
		var start = clampi(controller._weather_field_update_cursor, 0, maxi(0, expected_cells - 1))
		for offset in range(budget):
			var i = (start + offset) % expected_cells
			var pixel = Color(
				clampf(float(cloud_buffer[i]), 0.0, 1.0),
				clampf(float(rain_buffer[i]), 0.0, 1.0),
				clampf(float(humidity_buffer[i]), 0.0, 1.0),
				clampf(float(fog_buffer[i]), 0.0, 1.0)
			)
			var pack = pack_weather_color(pixel)
			if controller._weather_field_cache[i] == pack:
				continue
			controller._weather_field_cache[i] = pack
			var x = i % width
			var y = i / width
			controller._weather_field_image.set_pixel(x, y, pixel)
			dirty_count += 1
		controller._weather_field_update_cursor = (start + budget) % maxi(1, expected_cells)
	elif rows.size() < expected_cells and avg_pack != controller._weather_field_last_avg_pack:
		fill_weather_field(controller, fill_color, avg_pack)
		dirty_count = expected_cells
	controller._weather_field_last_avg_pack = avg_pack
	if not use_buffers:
		for row_variant in rows:
			if not (row_variant is Dictionary):
				continue
			var row = row_variant as Dictionary
			var x = int(row.get("x", -1))
			var y = int(row.get("y", -1))
			if x < 0 or x >= width or y < 0 or y >= height:
				continue
			var pixel = Color(
				clampf(float(row.get("cloud", avg_cloud)), 0.0, 1.0),
				clampf(float(row.get("rain", avg_rain)), 0.0, 1.0),
				clampf(float(row.get("humidity", avg_humidity)), 0.0, 1.0),
				clampf(float(row.get("fog", avg_fog)), 0.0, 1.0)
			)
			var pack = pack_weather_color(pixel)
			var idx = y * width + x
			if idx < 0 or idx >= controller._weather_field_cache.size():
				continue
			if controller._weather_field_cache[idx] == pack:
				continue
			controller._weather_field_cache[idx] = pack
			controller._weather_field_image.set_pixel(x, y, pixel)
			dirty_count += 1
	if dirty_count <= 0:
		return
	controller._weather_field_texture.update(controller._weather_field_image)

func pack_weather_color(c: Color) -> int:
	var r = int(clampi(int(round(c.r * 255.0)), 0, 255))
	var g = int(clampi(int(round(c.g * 255.0)), 0, 255))
	var b = int(clampi(int(round(c.b * 255.0)), 0, 255))
	var a = int(clampi(int(round(c.a * 255.0)), 0, 255))
	return r | (g << 8) | (b << 16) | (a << 24)

func fill_weather_field(controller: Node, color: Color, pack: int) -> void:
	if controller._weather_field_image == null:
		return
	controller._weather_field_image.fill(color)
	for i in range(controller._weather_field_cache.size()):
		controller._weather_field_cache[i] = pack
