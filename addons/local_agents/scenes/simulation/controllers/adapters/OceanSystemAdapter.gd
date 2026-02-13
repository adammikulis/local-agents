extends RefCounted
class_name OceanSystemAdapter

const WaterFlowShader = preload("res://addons/local_agents/scenes/simulation/shaders/VoxelWaterFlow.gdshader")

func ensure_ocean_surface(controller: Node) -> void:
	if not controller.ocean_surface_enabled:
		if controller._ocean_root != null and is_instance_valid(controller._ocean_root):
			controller._ocean_root.visible = false
		return
	controller._ensure_renderer_nodes()
	if controller._ocean_root == null:
		return
	controller._ocean_root.visible = true
	if controller._ocean_mesh_instance == null or not is_instance_valid(controller._ocean_mesh_instance):
		controller._ocean_mesh_instance = MeshInstance3D.new()
		controller._ocean_mesh_instance.name = "OceanSurface"
		controller._ocean_root.add_child(controller._ocean_mesh_instance)
	if controller._ocean_material == null:
		controller._ocean_material = ShaderMaterial.new()
		controller._ocean_material.shader = WaterFlowShader
	controller._ocean_mesh_instance.material_override = controller._ocean_material
	apply_ocean_material_uniforms(controller)

func update_ocean_surface_geometry(controller: Node) -> void:
	if not controller.ocean_surface_enabled:
		return
	ensure_ocean_surface(controller)
	if controller._ocean_mesh_instance == null:
		return
	var width = maxi(1, int(controller._generation_snapshot.get("width", 1)))
	var depth = maxi(1, int(controller._generation_snapshot.get("height", 1)))
	var voxel_world: Dictionary = controller._generation_snapshot.get("voxel_world", {})
	var sea_level = float(voxel_world.get("sea_level", 1))
	var next_size = Vector2(float(width), float(depth))
	if controller._ocean_plane_mesh == null:
		controller._ocean_plane_mesh = PlaneMesh.new()
	if controller._ocean_size_cache != next_size:
		controller._ocean_plane_mesh.size = next_size
		controller._ocean_size_cache = next_size
		controller._ocean_mesh_instance.mesh = controller._ocean_plane_mesh
	if not is_equal_approx(controller._ocean_sea_level_cache, sea_level):
		controller._ocean_sea_level_cache = sea_level
	controller._ocean_mesh_instance.position = Vector3(next_size.x * 0.5, sea_level + 0.52, next_size.y * 0.5)
	controller._ocean_mesh_instance.rotation_degrees = Vector3(-90.0, 0.0, 0.0)

func apply_ocean_material_uniforms(controller: Node) -> void:
	if not controller.ocean_surface_enabled:
		return
	if controller._ocean_material == null:
		return
	for key_variant in controller._water_shader_params.keys():
		controller._ocean_material.set_shader_parameter(String(key_variant), controller._water_shader_params[key_variant])
	controller._ocean_material.set_shader_parameter("weather_field_tex", controller._weather_field_texture)
	controller._ocean_material.set_shader_parameter("weather_field_world_size", controller._weather_field_world_size)
	controller._ocean_material.set_shader_parameter("weather_field_blend", 1.0)
	controller._ocean_material.set_shader_parameter("surface_field_tex", controller._surface_field_texture)
	controller._ocean_material.set_shader_parameter("surface_field_world_size", controller._weather_field_world_size)
	controller._ocean_material.set_shader_parameter("surface_field_blend", 1.0)
	controller._ocean_material.set_shader_parameter("solar_field_tex", controller._solar_field_texture)
	controller._ocean_material.set_shader_parameter("solar_field_world_size", controller._weather_field_world_size)
	controller._ocean_material.set_shader_parameter("solar_field_blend", 1.0)
