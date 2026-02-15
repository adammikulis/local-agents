extends Node3D
class_name LocalAgentsRiverRenderer

const RiverFlowShader = preload("res://addons/local_agents/scenes/simulation/shaders/VoxelRiverFlow.gdshader")

var _river_root: Node3D
var _river_material: ShaderMaterial

func clear_generated() -> void:
	if _river_root != null and is_instance_valid(_river_root):
		for child in _river_root.get_children():
			child.queue_free()

func rebuild_overlays(generation_snapshot: Dictionary, transform_stage_a_state: Dictionary) -> void:
	_ensure_root()
	for child in _river_root.get_children():
		child.queue_free()
	var flow_map: Dictionary = generation_snapshot.get("flow_map", {})
	var rows: Array = flow_map.get("rows", [])
	if rows.is_empty():
		return
	var surface_by_tile: Dictionary = {}
	var voxel_world: Dictionary = generation_snapshot.get("voxel_world", {})
	var columns: Array = voxel_world.get("columns", [])
	for col_variant in columns:
		if not (col_variant is Dictionary):
			continue
		var col = col_variant as Dictionary
		surface_by_tile["%d:%d" % [int(col.get("x", 0)), int(col.get("z", 0))]] = int(col.get("surface_y", 0))
	var transforms: Array = []
	var custom_rows: Array = []
	for row_variant in rows:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var strength = clampf(float(row.get("channel_strength", 0.0)), 0.0, 1.0)
		if strength < 0.2:
			continue
		var x = int(row.get("x", 0))
		var z = int(row.get("y", 0))
		var tile_id = "%d:%d" % [x, z]
		var y = float(surface_by_tile.get(tile_id, int(voxel_world.get("sea_level", 1)))) + 1.02
		var dir = Vector2(float(row.get("dir_x", 0.0)), float(row.get("dir_y", 0.0)))
		if dir.length_squared() < 0.0001:
			dir = Vector2(1.0, 0.0)
		dir = dir.normalized()
		transforms.append(Transform3D(Basis.IDENTITY, Vector3(float(x) + 0.5, y, float(z) + 0.5)))
		custom_rows.append(Color(dir.x * 0.5 + 0.5, dir.y * 0.5 + 0.5, strength, 1.0))
	if transforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.instance_count = transforms.size()
	var plane := PlaneMesh.new()
	plane.size = Vector2(1.0, 1.0)
	mm.mesh = plane
	for i in range(transforms.size()):
		mm.set_instance_transform(i, transforms[i])
		mm.set_instance_custom_data(i, custom_rows[i])
	var mi := MultiMeshInstance3D.new()
	mi.name = "RiverFlowMesh"
	mi.multimesh = mm
	if _river_material == null:
		_river_material = ShaderMaterial.new()
		_river_material.shader = RiverFlowShader
	mi.material_override = _river_material
	_river_root.add_child(mi)
	update_transform_stage(
		clampf(float(transform_stage_a_state.get("avg_rain_intensity", 0.0)), 0.0, 1.0),
		clampf(float(transform_stage_a_state.get("avg_cloud_cover", 0.0)), 0.0, 1.0),
		0.5
	)

func update_transform_stage(rain: float, cloud: float, wind_speed: float) -> void:
	if _river_material == null:
		return
	_river_material.set_shader_parameter("rain_intensity", rain)
	_river_material.set_shader_parameter("cloud_shadow", cloud * 0.85)
	_river_material.set_shader_parameter("flow_speed", 0.9 + wind_speed * 0.7)

func apply_lightning(lightning_flash: float) -> void:
	if _river_material != null:
		_river_material.set_shader_parameter("lightning_flash", lightning_flash)

func _ensure_root() -> void:
	if _river_root != null and is_instance_valid(_river_root):
		return
	_river_root = Node3D.new()
	_river_root.name = "RiverRoot"
	add_child(_river_root)
