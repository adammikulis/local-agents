extends RefCounted

var _owner: Variant
var _debug_overlay: Node3D
var _debug_smell_root: Node3D
var _debug_wind_root: Node3D
var _debug_temperature_root: Node3D
var _debug_voxel_mesh: BoxMesh
var _debug_arrow_mesh: BoxMesh
var _debug_voxel_material: StandardMaterial3D
var _debug_arrow_material: StandardMaterial3D
var _debug_smell_mm_instance: MultiMeshInstance3D
var _debug_temperature_mm_instance: MultiMeshInstance3D
var _debug_wind_mm_instance: MultiMeshInstance3D
var _debug_show_smell: bool = true
var _debug_show_wind: bool = true
var _debug_show_temperature: bool = true
var _debug_smell_layer: String = "all"
var _debug_accumulator: float = 0.0

func setup(owner: Variant) -> void:
	_owner = owner
	_ensure_debug_resources()

func set_debug_overlay(overlay: Node3D) -> void:
	_debug_overlay = overlay
	if _debug_overlay == null:
		return
	_debug_smell_root = _debug_overlay.get_node_or_null("SmellDebug")
	_debug_wind_root = _debug_overlay.get_node_or_null("WindDebug")
	_debug_temperature_root = _debug_overlay.get_node_or_null("TemperatureDebug")
	_ensure_debug_multimesh_instances()
	_apply_debug_visibility()

func apply_debug_settings(settings: Dictionary) -> void:
	_debug_show_smell = bool(settings.get("show_smell", _debug_show_smell))
	_debug_show_wind = bool(settings.get("show_wind", _debug_show_wind))
	_debug_show_temperature = bool(settings.get("show_temperature", _debug_show_temperature))
	_debug_smell_layer = String(settings.get("smell_layer", _debug_smell_layer)).to_lower().strip_edges()
	if _debug_smell_layer == "":
		_debug_smell_layer = "all"
	_apply_debug_visibility()

func set_debug_quality(density_scalar: float) -> void:
	var s = clampf(density_scalar, 0.2, 1.0)
	_owner.debug_max_smell_voxels = maxi(24, int(round(120.0 * s)))
	_owner.debug_max_temp_voxels = maxi(32, int(round(160.0 * s)))
	_owner.debug_max_wind_vectors = maxi(24, int(round(90.0 * s)))
	_owner.debug_refresh_seconds = lerpf(0.8, 0.3, s)
	_owner.debug_visual_scale = lerpf(0.5, 0.8, s)
	_debug_voxel_mesh = null
	_debug_arrow_mesh = null
	_ensure_debug_resources()
	if _debug_smell_mm_instance != null and is_instance_valid(_debug_smell_mm_instance):
		_debug_smell_mm_instance.queue_free()
		_debug_smell_mm_instance = null
	if _debug_temperature_mm_instance != null and is_instance_valid(_debug_temperature_mm_instance):
		_debug_temperature_mm_instance.queue_free()
		_debug_temperature_mm_instance = null
	if _debug_wind_mm_instance != null and is_instance_valid(_debug_wind_mm_instance):
		_debug_wind_mm_instance.queue_free()
		_debug_wind_mm_instance = null
	_ensure_debug_multimesh_instances()

func update_debug(delta: float) -> void:
	if _debug_overlay == null:
		return
	_ensure_debug_multimesh_instances()
	_debug_accumulator += delta
	if _debug_accumulator < _owner.debug_refresh_seconds:
		return
	_debug_accumulator = 0.0
	if _debug_smell_root != null and _debug_smell_root.visible:
		_render_smell_debug()
	if _debug_temperature_root != null and _debug_temperature_root.visible:
		_render_temperature_debug()
	if _debug_wind_root != null and _debug_wind_root.visible:
		_render_wind_debug()

func mark_voxel_mesh_dirty() -> void:
	_debug_voxel_mesh = null

func reset_debug_multimesh() -> void:
	if _debug_smell_mm_instance != null and _debug_smell_mm_instance.multimesh != null:
		_debug_smell_mm_instance.multimesh.instance_count = 0
	if _debug_temperature_mm_instance != null and _debug_temperature_mm_instance.multimesh != null:
		_debug_temperature_mm_instance.multimesh.instance_count = 0
	if _debug_wind_mm_instance != null and _debug_wind_mm_instance.multimesh != null:
		_debug_wind_mm_instance.multimesh.instance_count = 0

func _apply_debug_visibility() -> void:
	if _debug_smell_root != null:
		_debug_smell_root.visible = _debug_show_smell
	if _debug_wind_root != null:
		_debug_wind_root.visible = _debug_show_wind
	if _debug_temperature_root != null:
		_debug_temperature_root.visible = _debug_show_temperature

func _ensure_debug_resources() -> void:
	if _debug_voxel_mesh == null:
		_debug_voxel_mesh = BoxMesh.new()
		_debug_voxel_mesh.size = Vector3.ONE * (_owner.smell_voxel_size * 0.9 * _owner.debug_visual_scale)
	if _debug_arrow_mesh == null:
		_debug_arrow_mesh = BoxMesh.new()
		var arrow_scale = clampf(_owner.debug_visual_scale, 0.35, 1.0)
		_debug_arrow_mesh.size = Vector3(0.08, 0.08, 0.45) * arrow_scale
	if _debug_voxel_material == null:
		_debug_voxel_material = StandardMaterial3D.new()
		_debug_voxel_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_debug_voxel_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_debug_voxel_material.albedo_color = Color(1.0, 1.0, 1.0, 0.2)
	if _debug_arrow_material == null:
		_debug_arrow_material = StandardMaterial3D.new()
		_debug_arrow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_debug_arrow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_debug_arrow_material.albedo_color = Color(0.85, 0.92, 1.0, 0.35)

func _render_smell_debug() -> void:
	if _debug_smell_mm_instance == null or _debug_smell_root == null:
		return
	var camera = _debug_camera()
	var lod = _debug_lod_scale(camera)
	if lod <= 0.001:
		_commit_multimesh_instances(_debug_smell_mm_instance, [], [])
		return
	var budget := maxi(24, int(round(float(_owner.debug_max_smell_voxels) * lod)))
	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	match _debug_smell_layer:
		"food":
			_append_voxel_cells(_owner._smell_field.build_layer_cells("chem_cis_3_hexenol", 0.02, budget), Color(0.25, 0.95, 0.28, 0.2), 0.35, 0.12, transforms, colors, camera)
		"floral":
			_append_voxel_cells(_owner._smell_field.build_layer_cells("chem_linalool", 0.02, budget), Color(1.0, 0.86, 0.38, 0.2), 0.35, 0.16, transforms, colors, camera)
		"danger":
			_append_voxel_cells(_owner._smell_field.build_layer_cells("chem_ammonia", 0.02, budget), Color(1.0, 0.3, 0.3, 0.22), 0.35, 0.22, transforms, colors, camera)
		"hexanal":
			_append_voxel_cells(_owner._smell_field.build_layer_cells("chem_hexanal", 0.02, budget), Color(0.45, 0.95, 0.68, 0.2), 0.35, 0.14, transforms, colors, camera)
		"methyl_salicylate":
			_append_voxel_cells(_owner._smell_field.build_layer_cells("chem_methyl_salicylate", 0.02, budget), Color(0.95, 0.55, 0.95, 0.22), 0.35, 0.2, transforms, colors, camera)
		_:
			var food_cells: Array = _owner._smell_field.build_layer_cells("chem_cis_3_hexenol", 0.02, budget / 3)
			var floral_cells: Array = _owner._smell_field.build_layer_cells("chem_linalool", 0.02, budget / 3)
			var danger_cells: Array = _owner._smell_field.build_layer_cells("chem_ammonia", 0.02, budget / 3)
			_append_voxel_cells(food_cells, Color(0.25, 0.95, 0.28, 0.2), 0.35, 0.1, transforms, colors, camera)
			_append_voxel_cells(floral_cells, Color(1.0, 0.86, 0.38, 0.2), 0.35, 0.16, transforms, colors, camera)
			_append_voxel_cells(danger_cells, Color(1.0, 0.3, 0.3, 0.22), 0.35, 0.22, transforms, colors, camera)
	_commit_multimesh_instances(_debug_smell_mm_instance, transforms, colors)

func _render_temperature_debug() -> void:
	if _debug_temperature_mm_instance == null or _debug_temperature_root == null:
		return
	var camera = _debug_camera()
	var lod = _debug_lod_scale(camera)
	if lod <= 0.001:
		_commit_multimesh_instances(_debug_temperature_mm_instance, [], [])
		return
	var rows: Array = _owner._wind_field.build_temperature_cells(maxi(24, int(round(float(_owner.debug_max_temp_voxels) * lod))), 0.03)
	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	for row in rows:
		var world := Vector3(row.get("world", Vector3.ZERO))
		if not _debug_world_point_visible(camera, world):
			continue
		var temp := clampf(float(row.get("temperature", 0.0)), 0.0, 1.0)
		var color := Color(0.15, 0.35, 1.0, 0.16).lerp(Color(1.0, 0.2, 0.18, 0.3), temp)
		var world_lifted = world + Vector3(0.0, 0.35, 0.0)
		var local = _debug_temperature_root.to_local(world_lifted)
		transforms.append(Transform3D(Basis.IDENTITY, local))
		colors.append(color)
	_commit_multimesh_instances(_debug_temperature_mm_instance, transforms, colors)

func _render_wind_debug() -> void:
	if _debug_wind_mm_instance == null or _debug_wind_root == null:
		return
	var camera = _debug_camera()
	var lod = _debug_lod_scale(camera)
	if lod <= 0.001:
		_commit_multimesh_instances(_debug_wind_mm_instance, [], [])
		return
	var rows: Array = _owner._wind_field.build_debug_vectors(maxi(16, int(round(float(_owner.debug_max_wind_vectors) * lod))), 0.03)
	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	for row in rows:
		var world := Vector3(row.get("world", Vector3.ZERO)) + Vector3(0.0, 0.48, 0.0)
		if not _debug_world_point_visible(camera, world):
			continue
		var wind := Vector2(row.get("wind", Vector2.ZERO))
		var speed := float(row.get("speed", 0.0))
		if wind.length_squared() <= 0.00001:
			continue
		var forward = Vector3(wind.x, 0.0, wind.y).normalized()
		var right = Vector3.UP.cross(forward).normalized()
		if right.length_squared() < 0.00001:
			right = Vector3.RIGHT
		var basis := Basis(right, Vector3.UP, forward).scaled(Vector3(1.0, 1.0, clampf(0.6 + speed * 0.6, 0.6, 1.8)))
		var local = _debug_wind_root.to_local(world)
		transforms.append(Transform3D(basis, local))
		colors.append(Color(0.68, 0.92, 1.0, clampf(0.2 + speed * 0.28, 0.2, 0.55)))
	_commit_multimesh_instances(_debug_wind_mm_instance, transforms, colors)

func _append_voxel_cells(rows: Array[Dictionary], base_color: Color, alpha_scalar: float, y_lift: float, transforms: Array[Transform3D], colors: Array[Color], camera: Camera3D) -> void:
	if _debug_smell_root == null:
		return
	for row in rows:
		var world := Vector3(row.get("world", Vector3.ZERO)) + Vector3(0.0, y_lift, 0.0)
		if not _debug_world_point_visible(camera, world):
			continue
		var value := clampf(float(row.get("value", 0.0)), 0.0, 1.0)
		var color := base_color
		color.a = clampf(base_color.a + value * alpha_scalar, 0.12, 0.58)
		var local = _debug_smell_root.to_local(world)
		transforms.append(Transform3D(Basis.IDENTITY, local))
		colors.append(color)

func _debug_camera() -> Camera3D:
	var viewport = _owner.get_viewport()
	if viewport == null:
		return null
	return viewport.get_camera_3d()

func _debug_lod_scale(camera: Camera3D) -> float:
	if camera == null:
		return 1.0
	var dist = camera.global_position.distance_to(_owner.global_position)
	var near_dist = maxf(0.1, _owner.debug_near_full_detail_distance)
	var far_dist = maxf(near_dist + 0.5, _owner.debug_max_render_distance)
	if dist <= near_dist:
		return 1.0
	if dist >= far_dist:
		return 0.0
	var t = clampf((dist - near_dist) / (far_dist - near_dist), 0.0, 1.0)
	return lerpf(1.0, _owner.debug_far_lod_scale, t)

func _debug_world_point_visible(camera: Camera3D, world: Vector3) -> bool:
	if camera == null:
		return true
	var max_dist = maxf(1.0, _owner.debug_max_render_distance)
	if camera.global_position.distance_to(world) > max_dist:
		return false
	if camera.is_position_behind(world):
		return false
	var viewport = _owner.get_viewport()
	if viewport == null:
		return true
	var screen = camera.unproject_position(world)
	return viewport.get_visible_rect().grow(64.0).has_point(screen)

func _commit_multimesh_instances(instance: MultiMeshInstance3D, transforms: Array[Transform3D], colors: Array[Color]) -> void:
	if instance == null:
		return
	var mm := instance.multimesh
	if mm == null:
		return
	var count = mini(transforms.size(), colors.size())
	mm.instance_count = count
	for i in range(count):
		mm.set_instance_transform(i, transforms[i])
		mm.set_instance_color(i, colors[i])

func _ensure_debug_multimesh_instances() -> void:
	if _debug_smell_root != null and not is_instance_valid(_debug_smell_mm_instance):
		_debug_smell_mm_instance = _build_debug_mm_instance(_debug_voxel_mesh, _debug_voxel_material)
		_debug_smell_mm_instance.name = "SmellDebugMultiMesh"
		_debug_smell_root.add_child(_debug_smell_mm_instance)
	if _debug_temperature_root != null and not is_instance_valid(_debug_temperature_mm_instance):
		_debug_temperature_mm_instance = _build_debug_mm_instance(_debug_voxel_mesh, _debug_voxel_material)
		_debug_temperature_mm_instance.name = "TemperatureDebugMultiMesh"
		_debug_temperature_root.add_child(_debug_temperature_mm_instance)
	if _debug_wind_root != null and not is_instance_valid(_debug_wind_mm_instance):
		_debug_wind_mm_instance = _build_debug_mm_instance(_debug_arrow_mesh, _debug_arrow_material)
		_debug_wind_mm_instance.name = "WindDebugMultiMesh"
		_debug_wind_root.add_child(_debug_wind_mm_instance)

func _build_debug_mm_instance(mesh: Mesh, material: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = 0
	mm.mesh = mesh
	var out := MultiMeshInstance3D.new()
	out.multimesh = mm
	out.material_override = material
	return out
