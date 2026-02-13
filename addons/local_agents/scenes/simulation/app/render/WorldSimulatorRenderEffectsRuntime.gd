extends RefCounted
class_name LocalAgentsWorldSimulatorRenderEffectsRuntime

const VoxelTimelapseSnapshotResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/VoxelTimelapseSnapshotResource.gd")
const FlowFieldInstancedShader = preload("res://addons/local_agents/scenes/simulation/shaders/FlowFieldInstanced.gdshader")
const LavaSurfaceShader = preload("res://addons/local_agents/scenes/simulation/shaders/VoxelLavaSurface.gdshader")

func on_apply_terrain_preset_pressed(app) -> void:
	match app._terrain_preset_option.selected:
		0:
			app._surface_base_spin.value = 3.0
			app._surface_range_spin.value = 7.0
			app._sea_level_spin.value = 12.0
			app._noise_frequency_spin.value = 0.06
			app._noise_octaves_spin.value = 4.0
			app._noise_lacunarity_spin.value = 1.95
			app._noise_gain_spin.value = 0.48
			app._surface_smoothing_spin.value = 0.58
		1:
			app._surface_base_spin.value = 7.0
			app._surface_range_spin.value = 8.0
			app._sea_level_spin.value = 11.0
			app._noise_frequency_spin.value = 0.05
			app._noise_octaves_spin.value = 3.0
			app._noise_lacunarity_spin.value = 1.75
			app._noise_gain_spin.value = 0.38
			app._surface_smoothing_spin.value = 0.62
		2:
			app._surface_base_spin.value = 8.0
			app._surface_range_spin.value = 12.0
			app._sea_level_spin.value = 12.0
			app._noise_frequency_spin.value = 0.06
			app._noise_octaves_spin.value = 4.0
			app._noise_lacunarity_spin.value = 1.9
			app._noise_gain_spin.value = 0.44
			app._surface_smoothing_spin.value = 0.48
		_:
			app._surface_base_spin.value = 10.0
			app._surface_range_spin.value = 18.0
			app._sea_level_spin.value = 13.0
			app._noise_frequency_spin.value = 0.075
			app._noise_octaves_spin.value = 5.0
			app._noise_lacunarity_spin.value = 2.2
			app._noise_gain_spin.value = 0.54
			app._surface_smoothing_spin.value = 0.3
	app._generate_world()

func ensure_lava_root(app) -> void:
	if app._lava_root != null and is_instance_valid(app._lava_root):
		return
	app._lava_root = Node3D.new()
	app._lava_root.name = "LavaFXRoot"
	app.add_child(app._lava_root)
	app._lava_pool_cursor = 0

func clear_lava_fx(app) -> void:
	app._lava_pool_cursor = 0
	for fx_variant in app._lava_fx:
		if not (fx_variant is Dictionary):
			continue
		var fx = fx_variant as Dictionary
		fx["ttl"] = 0.0
		var node = fx.get("node", null)
		if node is Node3D and is_instance_valid(node):
			(node as Node3D).visible = false
	if app._lava_root != null and is_instance_valid(app._lava_root):
		for child in app._lava_root.get_children():
			child.queue_free()
	app._lava_fx.clear()

func ensure_lava_pool(app) -> void:
	ensure_lava_root(app)
	var pool_size = maxi(4, app.max_active_lava_fx)
	if app._lava_fx.size() >= pool_size:
		return
	for _i in range(app._lava_fx.size(), pool_size):
		var root := Node3D.new()
		root.visible = false
		app._lava_root.add_child(root)
		var mesh := MeshInstance3D.new()
		var disc := CylinderMesh.new()
		disc.top_radius = 0.7
		disc.bottom_radius = 0.95
		disc.height = 0.28
		mesh.mesh = disc
		var lava_mat := ShaderMaterial.new()
		lava_mat.shader = LavaSurfaceShader
		mesh.material_override = lava_mat
		root.add_child(mesh)
		var particles := GPUParticles3D.new()
		particles.amount = 84
		particles.lifetime = 1.4
		particles.preprocess = 0.4
		particles.one_shot = true
		particles.explosiveness = 0.78
		particles.randomness = 0.45
		particles.draw_pass_1 = SphereMesh.new()
		var process := ParticleProcessMaterial.new()
		process.direction = Vector3(0.0, 1.0, 0.0)
		process.initial_velocity_min = 2.3
		process.initial_velocity_max = 5.8
		process.gravity = Vector3(0.0, -8.5, 0.0)
		process.scale_min = 0.08
		process.scale_max = 0.22
		process.color = Color(1.0, 0.38, 0.1, 1.0)
		particles.process_material = process
		root.add_child(particles)
		app._lava_fx.append({
			"node": root,
			"material": lava_mat,
			"particles": particles,
			"ttl": 0.0,
		})

func spawn_lava_plume(app, volcano: Dictionary) -> void:
	ensure_lava_pool(app)
	if app._lava_fx.is_empty():
		return
	var pool_size = app._lava_fx.size()
	var fx_idx = app._lava_pool_cursor % pool_size
	app._lava_pool_cursor = (app._lava_pool_cursor + 1) % pool_size
	var fx = app._lava_fx[fx_idx] as Dictionary
	var vx = float(volcano.get("x", 0)) + 0.5
	var vz = float(volcano.get("y", 0)) + 0.5
	var tile_id = "%d:%d" % [int(volcano.get("x", 0)), int(volcano.get("y", 0))]
	var height = surface_height_for_tile(app, tile_id) + 1.1
	var root = fx.get("node", null)
	if not (root is Node3D) or not is_instance_valid(root):
		return
	var root_node = root as Node3D
	root_node.name = "LavaFX_%s" % tile_id.replace(":", "_")
	root_node.visible = true
	root_node.position = Vector3(vx, height, vz)
	var lava_mat = fx.get("material", null)
	if lava_mat is ShaderMaterial:
		var smat := lava_mat as ShaderMaterial
		smat.set_shader_parameter("flow_speed", 1.6 + float(volcano.get("activity", 0.5)) * 2.2)
		smat.set_shader_parameter("pulse_strength", 1.0 + float(volcano.get("activity", 0.5)))
		smat.set_shader_parameter("cooling", 0.0)
	var particles = fx.get("particles", null)
	if particles is GPUParticles3D:
		var p = particles as GPUParticles3D
		p.emitting = false
		p.restart()
		p.emitting = true
	fx["ttl"] = 4.0
	app._lava_fx[fx_idx] = fx

func update_lava_fx(app, delta: float) -> void:
	if app._lava_fx.is_empty():
		return
	for i in range(app._lava_fx.size()):
		var fx_variant = app._lava_fx[i]
		if not (fx_variant is Dictionary):
			continue
		var fx = fx_variant as Dictionary
		var ttl = float(fx.get("ttl", 0.0)) - delta
		var node = fx.get("node", null)
		var material = fx.get("material", null)
		if material is ShaderMaterial:
			var cool = clampf(1.0 - ttl / 4.0, 0.0, 1.0)
			(material as ShaderMaterial).set_shader_parameter("cooling", cool)
		if ttl <= 0.0:
			if node is Node3D and is_instance_valid(node):
				(node as Node3D).visible = false
			fx["ttl"] = 0.0
			app._lava_fx[i] = fx
			continue
		fx["ttl"] = ttl
		app._lava_fx[i] = fx

func surface_height_for_tile(app, tile_id: String) -> float:
	var voxel_world: Dictionary = app._world_snapshot.get("voxel_world", {})
	var columns: Array = voxel_world.get("columns", [])
	var column_index: Dictionary = voxel_world.get("column_index_by_tile", {})
	if column_index.has(tile_id):
		var idx = int(column_index.get(tile_id, -1))
		if idx >= 0 and idx < columns.size() and columns[idx] is Dictionary:
			return float((columns[idx] as Dictionary).get("surface_y", 0))
	for column_variant in columns:
		if not (column_variant is Dictionary):
			continue
		var column = column_variant as Dictionary
		var cid = "%d:%d" % [int(column.get("x", 0)), int(column.get("z", 0))]
		if cid == tile_id:
			return float(column.get("surface_y", 0))
	return float(voxel_world.get("sea_level", 1))

func record_timelapse_snapshot(app, tick: int) -> void:
	var snapshot_resource = VoxelTimelapseSnapshotResourceScript.new()
	snapshot_resource.tick = tick
	snapshot_resource.time_of_day = app._time_of_day
	snapshot_resource.simulated_year = app._year_at_tick(tick)
	snapshot_resource.simulated_seconds = app._simulated_seconds
	snapshot_resource.world = app._world_snapshot.duplicate(true)
	snapshot_resource.hydrology = app._hydrology_snapshot.duplicate(true)
	snapshot_resource.weather = app._weather_snapshot.duplicate(true)
	snapshot_resource.erosion = app._erosion_snapshot.duplicate(true)
	snapshot_resource.solar = app._solar_snapshot.duplicate(true)
	app._timelapse_snapshots[tick] = snapshot_resource
	var keys = app._timelapse_snapshots.keys()
	var max_snapshots = 192 if app._ultra_perf_mode else 480
	if keys.size() <= max_snapshots:
		return
	keys.sort()
	var drop_count = keys.size() - max_snapshots
	for i in range(drop_count):
		app._timelapse_snapshots.erase(keys[i])

func render_flow_overlay(app, world: Dictionary, config) -> void:
	ensure_flow_overlay_multimesh(app)
	if app._flow_overlay_mm_instance == null or app._flow_overlay_mm_instance.multimesh == null:
		return
	var mm := app._flow_overlay_mm_instance.multimesh
	if not app._show_flow_checkbox.button_pressed:
		mm.instance_count = 0
		return
	var flow_map: Dictionary = world.get("flow_map", {})
	if flow_map.is_empty():
		mm.instance_count = 0
		return
	var width = int(flow_map.get("width", int(world.get("width", 0))))
	var height = int(flow_map.get("height", int(world.get("height", 0))))
	if width <= 0 or height <= 0:
		mm.instance_count = 0
		return
	var stride = maxi(1, int(app._flow_stride_spin.value))
	var grid_w = maxi(1, int(ceil(float(width) / float(stride))))
	var grid_h = maxi(1, int(ceil(float(height) / float(stride))))
	var instance_count = grid_w * grid_h
	if app._flow_overlay_grid_w != grid_w or app._flow_overlay_grid_h != grid_h or app._flow_overlay_stride != stride:
		app._flow_overlay_grid_w = grid_w
		app._flow_overlay_grid_h = grid_h
		app._flow_overlay_stride = stride
		app._flow_overlay_instance_count = instance_count
		mm.instance_count = instance_count
		for i in range(instance_count):
			mm.set_instance_transform(i, Transform3D.IDENTITY)
	else:
		mm.instance_count = instance_count
	if app._flow_overlay_dirty:
		update_flow_overlay_textures(app, world, flow_map, config)
		app._flow_overlay_dirty = false
	if app._flow_overlay_material != null:
		app._flow_overlay_material.set_shader_parameter("flow_texture", app._flow_overlay_dir_texture)
		app._flow_overlay_material.set_shader_parameter("height_texture", app._flow_overlay_height_texture)
		app._flow_overlay_material.set_shader_parameter("grid_width", grid_w)
		app._flow_overlay_material.set_shader_parameter("grid_height", grid_h)
		app._flow_overlay_material.set_shader_parameter("sample_stride", stride)
		app._flow_overlay_material.set_shader_parameter("strength_threshold", clampf(float(app._flow_strength_threshold_spin.value), 0.0, 1.0))
		app._flow_overlay_material.set_shader_parameter("sea_level", float(config.voxel_sea_level))
		app._flow_overlay_material.set_shader_parameter("time_sec", app._simulated_seconds)
		app._flow_overlay_material.set_shader_parameter("cell_size", 1.0)

func ensure_flow_overlay_multimesh(app) -> void:
	if app._flow_overlay_root == null:
		return
	if app._flow_overlay_mesh == null:
		app._flow_overlay_mesh = BoxMesh.new()
		app._flow_overlay_mesh.size = Vector3(0.08, 0.06, 1.0)
	if app._flow_overlay_material == null:
		app._flow_overlay_material = ShaderMaterial.new()
		app._flow_overlay_material.shader = FlowFieldInstancedShader
	if app._flow_overlay_mm_instance != null and is_instance_valid(app._flow_overlay_mm_instance):
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = false
	mm.use_custom_data = false
	mm.mesh = app._flow_overlay_mesh
	mm.instance_count = 0
	app._flow_overlay_mm_instance = MultiMeshInstance3D.new()
	app._flow_overlay_mm_instance.multimesh = mm
	app._flow_overlay_mm_instance.material_override = app._flow_overlay_material
	app._flow_overlay_mm_instance.name = "FlowOverlayMultiMesh"
	app._flow_overlay_root.add_child(app._flow_overlay_mm_instance)

func update_flow_overlay_textures(app, world: Dictionary, flow_map: Dictionary, config) -> void:
	var width = int(flow_map.get("width", int(world.get("width", 0))))
	var height = int(flow_map.get("height", int(world.get("height", 0))))
	if width <= 0 or height <= 0:
		return
	if app._flow_overlay_dir_image == null or app._flow_overlay_dir_image.get_width() != width or app._flow_overlay_dir_image.get_height() != height:
		app._flow_overlay_dir_image = Image.create(width, height, false, Image.FORMAT_RGBA8)
		app._flow_overlay_height_image = Image.create(width, height, false, Image.FORMAT_RF)
		app._flow_overlay_dir_texture = ImageTexture.create_from_image(app._flow_overlay_dir_image)
		app._flow_overlay_height_texture = ImageTexture.create_from_image(app._flow_overlay_height_image)
	app._flow_overlay_dir_image.fill(Color(0.5, 0.5, 0.0, 1.0))
	app._flow_overlay_height_image.fill(Color(float(config.voxel_sea_level), 0.0, 0.0, 1.0))
	var voxel_world: Dictionary = world.get("voxel_world", {})
	var columns: Array = voxel_world.get("columns", [])
	var surface_buf: PackedInt32Array = voxel_world.get("surface_y_buffer", PackedInt32Array())
	if surface_buf.size() == width * height:
		for z in range(height):
			for x in range(width):
				var flat = z * width + x
				var h = float(surface_buf[flat])
				app._flow_overlay_height_image.set_pixel(x, z, Color(h, 0.0, 0.0, 1.0))
	else:
		for column_variant in columns:
			if not (column_variant is Dictionary):
				continue
			var column = column_variant as Dictionary
			var x = int(column.get("x", 0))
			var z = int(column.get("z", 0))
			if x < 0 or x >= width or z < 0 or z >= height:
				continue
			var h = float(int(column.get("surface_y", config.voxel_sea_level)))
			app._flow_overlay_height_image.set_pixel(x, z, Color(h, 0.0, 0.0, 1.0))
	var rows: Array = flow_map.get("rows", [])
	var packed_dx: PackedFloat32Array = flow_map.get("flow_dir_x_buffer", PackedFloat32Array())
	var packed_dy: PackedFloat32Array = flow_map.get("flow_dir_y_buffer", PackedFloat32Array())
	var packed_strength: PackedFloat32Array = flow_map.get("flow_strength_buffer", PackedFloat32Array())
	if packed_dx.size() == width * height and packed_dy.size() == width * height and packed_strength.size() == width * height:
		for z in range(height):
			for x in range(width):
				var flat = z * width + x
				var dir = Vector2(float(packed_dx[flat]), float(packed_dy[flat]))
				var strength = clampf(float(packed_strength[flat]), 0.0, 1.0)
				if dir.length_squared() > 0.00001:
					dir = dir.normalized()
				app._flow_overlay_dir_image.set_pixel(x, z, Color(dir.x * 0.5 + 0.5, dir.y * 0.5 + 0.5, strength, 1.0))
	else:
		for row_variant in rows:
			if not (row_variant is Dictionary):
				continue
			var row = row_variant as Dictionary
			var x = int(row.get("x", 0))
			var z = int(row.get("y", 0))
			if x < 0 or x >= width or z < 0 or z >= height:
				continue
			var dir = Vector2(float(row.get("dir_x", 0.0)), float(row.get("dir_y", 0.0)))
			var strength = clampf(float(row.get("channel_strength", 0.0)), 0.0, 1.0)
			if dir.length_squared() > 0.00001:
				dir = dir.normalized()
			app._flow_overlay_dir_image.set_pixel(x, z, Color(dir.x * 0.5 + 0.5, dir.y * 0.5 + 0.5, strength, 1.0))
	if app._flow_overlay_dir_texture != null:
		app._flow_overlay_dir_texture.update(app._flow_overlay_dir_image)
	if app._flow_overlay_height_texture != null:
		app._flow_overlay_height_texture.update(app._flow_overlay_height_image)

func update_day_night(app, delta: float) -> void:
	if app._sun_light == null:
		return
	app._time_of_day = app._atmosphere_cycle.advance_time(app._time_of_day, delta, app.day_night_cycle_enabled, app.day_length_seconds)
	app._atmosphere_cycle.apply_to_light_and_environment(
		app._time_of_day,
		app._sun_light,
		app._world_environment,
		0.06,
		1.38,
		0.04,
		1.15,
		0.02,
		1.0,
		0.05,
		1.0
	)
	app._apply_demo_fog()
