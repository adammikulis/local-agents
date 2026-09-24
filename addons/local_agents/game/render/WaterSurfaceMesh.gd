class_name LAWaterSurfaceMesh
extends RefCounted

## THE FREE SURFACE OF THE FIELD'S LIQUID: one quad per cell holding water with air over it.


## Build the water surface. Returns {"verts": PackedVector3Array, "normals": PackedVector3Array,
## "indices": PackedInt32Array, "count": int}. `count`==0 → nothing to draw.
func build(field, inv_xform: Transform3D, cam_radial: Vector3, cap_cos: float,
		render_min: float, max_mass: float) -> Dictionary:
	var verts: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var indices: PackedInt32Array = PackedInt32Array()
	var grid: LAVoxelGrid = field._grid
	var q = field._queries
	var solid: PackedByteArray = field._solid
	var out: Dictionary = {"verts": verts, "normals": normals, "indices": indices, "count": 0}
	if grid == null or solid.size() != grid.cell_count or field._rock_fraction.size() != grid.cell_count:
		return out
	var centre: Vector3 = LAFieldGeometry.centre(field)
	# The grid is laid in the body's frame, which the spin turns under the world's.
	var cam_f: Vector3 = field.dir_to_field(cam_radial)

	for c in field._mirrors.cells_with_phase_mass("h2o", "h2o_liquid", render_min):
		if solid[c] != 0:
			continue
		var hi: int = LAFieldGeometry.above(field, c)
		if hi >= 0 and (solid[hi] != 0 or q.liquid_at(hi) >= render_min):
			continue                                   # not the free surface: more water or rock above
		var pos: Vector3 = grid.cell_world_pos(c)
		var radial: Vector3 = pos - centre
		var r: float = radial.length()
		if r < 0.001 or radial.dot(cam_f) / r < cap_cos:
			continue                                   # outside the visible cap → skip (relevance LOD)
		var up: Vector3 = LAFieldGeometry.up(field, c)
		if up == Vector3.ZERO:
			continue
		# The level the cell's rock and water fill it to, rock under water, in the cell's own edge.
		var edge: float = grid.cell_edge(c)
		var fill: float = clampf(field._rock_fraction[c] + q.liquid_at(c) / max_mass, 0.0, 1.0)
		var top: Vector3 = pos + up * (fill - 0.5) * edge
		var a: Vector3 = up.cross(cam_f)
		if a.length_squared() < 1.0e-8:
			a = up.cross(Vector3.RIGHT)
		a = a.normalized() * 0.5 * edge
		var b: Vector3 = up.cross(a).normalized() * 0.5 * edge
		var base: int = verts.size()
		for corner in [-a - b, a - b, a + b, -a + b]:
			verts.push_back(inv_xform * field.field_to_point(top + corner))
			normals.push_back(Vector3.UP)              # placeholder; VoxelWater.gdshader recomputes NORMAL
		indices.push_back(base); indices.push_back(base + 1); indices.push_back(base + 2)
		indices.push_back(base); indices.push_back(base + 2); indices.push_back(base + 3)

	out["verts"] = verts
	out["normals"] = normals
	out["indices"] = indices
	out["count"] = verts.size()
	return out
