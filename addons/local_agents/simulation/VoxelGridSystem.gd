extends RefCounted
class_name LocalAgentsVoxelGridSystem

var _half_extent: float = 10.0
var _voxel_size: float = 0.5
var _vertical_half_extent: float = 3.0
var _invalid_voxel := Vector3i(2147483647, 2147483647, 2147483647)

func configure(half_extent: float, voxel_size: float, vertical_half_extent: float = 3.0) -> void:
	_half_extent = maxf(1.0, half_extent)
	_voxel_size = maxf(0.1, voxel_size)
	_vertical_half_extent = maxf(_voxel_size, vertical_half_extent)

func half_extent() -> float:
	return _half_extent

func voxel_size() -> float:
	return _voxel_size

func vertical_half_extent() -> float:
	return _vertical_half_extent

func invalid_voxel() -> Vector3i:
	return _invalid_voxel

func world_to_voxel(world_position: Vector3) -> Vector3i:
	var voxel := Vector3i(
		int(round(world_position.x / _voxel_size)),
		int(round(world_position.y / _voxel_size)),
		int(round(world_position.z / _voxel_size))
	)
	if not is_inside(voxel):
		return _invalid_voxel
	return voxel

func voxel_to_world(voxel: Vector3i) -> Vector3:
	return Vector3(
		float(voxel.x) * _voxel_size,
		float(voxel.y) * _voxel_size,
		float(voxel.z) * _voxel_size
	)

func is_inside(voxel: Vector3i) -> bool:
	var horizontal := Vector2(float(voxel.x) * _voxel_size, float(voxel.z) * _voxel_size)
	if horizontal.length() > _half_extent:
		return false
	return absf(float(voxel.y) * _voxel_size) <= _vertical_half_extent

func neighbors_6(voxel: Vector3i) -> Array[Vector3i]:
	var offsets: Array[Vector3i] = [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0),
		Vector3i(0, -1, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1),
	]
	var rows: Array[Vector3i] = []
	for offset in offsets:
		var candidate := voxel + offset
		if is_inside(candidate):
			rows.append(candidate)
	return rows

func all_ground_voxels() -> Array[Vector3i]:
	var rows: Array[Vector3i] = []
	var radius_cells := int(ceil(_half_extent / _voxel_size))
	for z in range(-radius_cells, radius_cells + 1):
		for x in range(-radius_cells, radius_cells + 1):
			var voxel := Vector3i(x, 0, z)
			if is_inside(voxel):
				rows.append(voxel)
	rows.sort_custom(_sort_voxels)
	return rows

func sort_voxel_keys(keys: Array) -> Array:
	keys.sort_custom(_sort_voxels)
	return keys

func _sort_voxels(a: Variant, b: Variant) -> bool:
	var va: Vector3i = a
	var vb: Vector3i = b
	if va.x != vb.x:
		return va.x < vb.x
	if va.y != vb.y:
		return va.y < vb.y
	return va.z < vb.z
