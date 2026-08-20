class_name LAWaterSurfaceMesh
extends RefCounted

## The free water surface as geometry: one quad on the top face of every surfaced cell near the camera.

const SEA_BIAS: float = 0.4   # draw the near-cap sea this far outside the ocean sphere so it occludes it


## Build the water surface. Returns {"verts": PackedVector3Array, "normals": PackedVector3Array,
## "colors": PackedColorArray, "indices": PackedInt32Array, "count": int}. `count`==0 → nothing to draw.
func build(field, inv_xform: Transform3D, cam_radial: Vector3, cap_cos: float,
		render_min: float, max_mass: float, sea_radius: float, sea_wave_eps: float) -> Dictionary:
	var verts: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var colors: PackedColorArray = PackedColorArray()
	var indices: PackedInt32Array = PackedInt32Array()
	var grid: LAVoxelGrid = field._grid
	var water: PackedFloat32Array = field._queries._liquid_mirror()
	var solid: PackedByteArray = field._solid
	var out: Dictionary = {"verts": verts, "normals": normals, "colors": colors,
		"indices": indices, "count": 0}
	if grid == null or water.size() != grid.cell_count or solid.size() != grid.cell_count:
		return out
	var centre: Vector3 = LAFieldGeometry.centre(field)
	var half: float = 0.5 * grid.cell_size

	for c in grid.cell_count:
		if solid[c] != 0 or water[c] < render_min:
			continue
		var hi: int = LAFieldGeometry.above(field, c)
		if hi >= 0 and (solid[hi] != 0 or water[hi] >= render_min):
			continue                                   # not the free surface: more water or rock above
		var pos: Vector3 = grid.cell_world_pos(c)
		var radial: Vector3 = pos - centre
		var r: float = radial.length()
		if r < 0.001 or radial.dot(cam_radial) / r < cap_cos:
			continue                                   # outside the visible cap → skip (relevance LOD)
		var up: Vector3 = LAFieldGeometry.up(field, c)
		if up == Vector3.ZERO:
			continue
		# Sub-cell height, so a half-full cell reads as a shoreline rather than a step.
		var fill: float = clampf(water[c] / max_mass, 0.0, 1.0)
		var top: Vector3 = pos + up * (fill - 0.5) * grid.cell_size
		# Salt where the surface stands at the sea shell, fresh where it stands above it.
		var salinity: float = 0.0
		if absf(r - sea_radius) <= sea_wave_eps:
			salinity = 1.0
			top = centre + radial / r * (sea_radius + SEA_BIAS)
		var a: Vector3 = up.cross(cam_radial)
		if a.length_squared() < 1.0e-8:
			a = up.cross(Vector3.RIGHT)
		a = a.normalized() * half
		var b: Vector3 = up.cross(a).normalized() * half
		var base: int = verts.size()
		for corner in [-a - b, a - b, a + b, -a + b]:
			verts.push_back(inv_xform * (top + corner))
			normals.push_back(Vector3.UP)              # placeholder; VoxelWater.gdshader recomputes NORMAL
			colors.push_back(Color(0.5, 0.5, 0.0, salinity))
		indices.push_back(base); indices.push_back(base + 1); indices.push_back(base + 2)
		indices.push_back(base); indices.push_back(base + 2); indices.push_back(base + 3)

	out["verts"] = verts
	out["normals"] = normals
	out["colors"] = colors
	out["indices"] = indices
	out["count"] = verts.size()
	return out
