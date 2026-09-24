class_name LATerrainLook
extends RefCounted

## The material a view dresses the planet's VoxelLodTerrain with. godot_voxel copies it into each block as
## the block is made, so a uniform reaches every block only in a new material the terrain is handed.


## Draw `terrain` with `mat`: where the terrain's own frame stands in the world, and the ground's reflectance.
static func dress(terrain: Node, mat: ShaderMaterial) -> void:
	var voxel: VoxelLodTerrain = terrain as VoxelLodTerrain
	if voxel == null or mat == null:
		return
	mat.set_shader_parameter("terrain_origin", voxel.global_position)
	mat.set_shader_parameter("albedo_bare_ground", LAPhysical.ALBEDO_BARE_GROUND)
	mat.set_shader_parameter("albedo_snow_ice", LAPhysical.ALBEDO_SNOW_ICE)
	voxel.material = mat


## Write `params` (uniform -> value) into every block's material.
static func set_params(terrain: Node, params: Dictionary) -> void:
	var voxel: VoxelLodTerrain = terrain as VoxelLodTerrain
	if voxel == null or not (voxel.material is ShaderMaterial):
		return
	var mat: ShaderMaterial = voxel.material.duplicate() as ShaderMaterial
	for key in params:
		mat.set_shader_parameter(String(key), params[key])
	voxel.material = mat
