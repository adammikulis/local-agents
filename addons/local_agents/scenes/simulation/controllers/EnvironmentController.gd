extends Node3D

const WaterFlowShader = preload("res://addons/local_agents/scenes/simulation/shaders/VoxelWaterFlow.gdshader")

@onready var terrain_root: Node3D = $TerrainRoot
@onready var water_root: Node3D = $WaterRoot
var _generation_snapshot: Dictionary = {}
var _hydrology_snapshot: Dictionary = {}
var _material_cache: Dictionary = {}
var _water_shader_params := {
	"flow_dir": Vector2(1.0, 0.2),
	"flow_speed": 0.95,
	"noise_scale": 0.48,
	"foam_strength": 0.36,
	"wave_strength": 0.32,
}

func clear_generated() -> void:
	for child in terrain_root.get_children():
		child.queue_free()
	for child in water_root.get_children():
		child.queue_free()
	_material_cache.clear()

func apply_generation_data(generation: Dictionary, hydrology: Dictionary) -> void:
	_generation_snapshot = generation.duplicate(true)
	_hydrology_snapshot = hydrology.duplicate(true)
	clear_generated()
	_build_voxel_terrain()

	var source_tiles: Array = _hydrology_snapshot.get("source_tiles", [])
	source_tiles.sort()
	for tile_id_variant in source_tiles:
		var marker := Marker3D.new()
		marker.name = "WaterSource_%s" % String(tile_id_variant).replace(":", "_")
		var coords = String(tile_id_variant).split(":")
		if coords.size() == 2:
			marker.position = Vector3(float(coords[0]), 0.1, float(coords[1]))
		water_root.add_child(marker)

func get_generation_snapshot() -> Dictionary:
	return _generation_snapshot.duplicate(true)

func get_hydrology_snapshot() -> Dictionary:
	return _hydrology_snapshot.duplicate(true)

func set_water_shader_params(params: Dictionary) -> void:
	for key_variant in params.keys():
		var key = String(key_variant)
		_water_shader_params[key] = params.get(key_variant)
	var material = _material_cache.get("water", null)
	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		for key_variant in _water_shader_params.keys():
			var key = String(key_variant)
			shader_material.set_shader_parameter(key, _water_shader_params[key_variant])

func _build_voxel_terrain() -> void:
	var voxel_world: Dictionary = _generation_snapshot.get("voxel_world", {})
	var block_rows: Array = voxel_world.get("block_rows", [])
	if block_rows.is_empty():
		return

	var grouped: Dictionary = {}
	for block_variant in block_rows:
		if not (block_variant is Dictionary):
			continue
		var block: Dictionary = block_variant
		var block_type = String(block.get("type", "air"))
		if block_type == "air":
			continue
		if not grouped.has(block_type):
			grouped[block_type] = []
		var pos = Vector3(
			float(block.get("x", 0)) + 0.5,
			float(block.get("y", 0)) + 0.5,
			float(block.get("z", 0)) + 0.5
		)
		(grouped[block_type] as Array).append(pos)

	var block_types = grouped.keys()
	block_types.sort_custom(func(a, b): return String(a) < String(b))
	for type_variant in block_types:
		var block_type = String(type_variant)
		var positions: Array = grouped.get(block_type, [])
		if positions.is_empty():
			continue
		var mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.instance_count = positions.size()
		mm.mesh = _mesh_for_block(block_type)
		for i in range(positions.size()):
			var transform = Transform3D(Basis.IDENTITY, positions[i])
			mm.set_instance_transform(i, transform)
		var instance := MultiMeshInstance3D.new()
		instance.name = "Terrain_%s" % block_type
		instance.multimesh = mm
		instance.material_override = _material_for_block(block_type)
		terrain_root.add_child(instance)

func _mesh_for_block(block_type: String) -> Mesh:
	if block_type == "water":
		var water_mesh := BoxMesh.new()
		water_mesh.size = Vector3(1.0, 0.92, 1.0)
		return water_mesh
	var cube := BoxMesh.new()
	cube.size = Vector3.ONE
	return cube

func _material_for_block(block_type: String) -> Material:
	if _material_cache.has(block_type):
		return _material_cache[block_type]
	if block_type == "water":
		var water_material := ShaderMaterial.new()
		water_material.shader = WaterFlowShader
		for key_variant in _water_shader_params.keys():
			var key = String(key_variant)
			water_material.set_shader_parameter(key, _water_shader_params[key_variant])
		_material_cache[block_type] = water_material
		return water_material
	var material := StandardMaterial3D.new()
	material.albedo_color = _block_color(block_type)
	material.roughness = 0.95
	_material_cache[block_type] = material
	return material

func _block_color(block_type: String) -> Color:
	match block_type:
		"grass":
			return Color(0.28, 0.63, 0.2, 1.0)
		"dirt":
			return Color(0.46, 0.31, 0.2, 1.0)
		"clay":
			return Color(0.58, 0.48, 0.42, 1.0)
		"sand":
			return Color(0.8, 0.74, 0.51, 1.0)
		"snow":
			return Color(0.9, 0.94, 0.98, 1.0)
		"stone":
			return Color(0.45, 0.45, 0.47, 1.0)
		"gravel":
			return Color(0.52, 0.5, 0.48, 1.0)
		"coal_ore":
			return Color(0.22, 0.22, 0.22, 1.0)
		"copper_ore":
			return Color(0.66, 0.43, 0.25, 1.0)
		"iron_ore":
			return Color(0.58, 0.47, 0.35, 1.0)
		"water":
			return Color(0.18, 0.35, 0.76, 0.62)
		_:
			return Color(1.0, 0.0, 1.0, 1.0)
