class_name LAWaterSurfaceMesh
extends RefCounted

## THE FREE SURFACE OF THE FIELD'S LIQUID, in the field's frame about `anchor`: in each of the grid's finest cells
## whose water rests on rock or water, the plane normal to gravity with the cell's rock and liquid beneath it.
## Returns {"verts", "normals" (the local vertical), "uvs" (x: the cell's edge, m), "indices", "count"}.
func build(field, anchor: Vector3, cam_dir: Vector3, cap_cos: float, render_min: float,
		max_mass: float) -> Dictionary:
	var verts: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var indices: PackedInt32Array = PackedInt32Array()
	var grid: LAVoxelGrid = field._grid
	var q = field._queries
	var solid: PackedByteArray = field._solid
	var out: Dictionary = {"verts": verts, "normals": normals, "uvs": uvs, "indices": indices, "count": 0}
	if grid == null or solid.size() != grid.cell_count or field._rock_fraction.size() != grid.cell_count:
		return out
	var centre: Vector3 = LAFieldGeometry.centre(field)

	for c in field._mirrors.cells_with_phase_mass("h2o", "h2o_liquid", render_min):
		if solid[c] != 0 or grid.level_of(c) != grid.max_level:
			continue
		var lo: int = LAFieldGeometry.below(field, c)
		if lo < 0 or (solid[lo] == 0 and q.liquid_at(lo) < render_min):
			continue                                   # held up by nothing: droplets, not a body of water
		var pos: Vector3 = grid.cell_world_pos(c)
		var radial: Vector3 = pos - centre
		var r: float = radial.length()
		if r < 0.001 or radial.dot(cam_dir) / r < cap_cos:
			continue                                   # outside the visible cap → skip (relevance LOD)
		var up: Vector3 = LAFieldGeometry.up(field, c)
		if up == Vector3.ZERO:
			continue
		var fill: float = field._rock_fraction[c] + q.liquid_at(c) / max_mass
		if not (fill < 1.0):
			continue                                   # no gas left in the cell, so no surface in it
		# LA_APPROX: water_surface_plane_per_cell
		var poly: PackedVector3Array = section(up, level_holding(up, fill))
		if poly.size() < 3:
			continue
		var edge: float = grid.cell_edge(c)
		var corner: Vector3 = pos - Vector3.ONE * (0.5 * edge) - anchor
		var base: int = verts.size()
		for p in poly:
			verts.push_back(corner + p * edge)
			normals.push_back(up)
			uvs.push_back(Vector2(edge, 0.0))
		for k in range(1, poly.size() - 1):
			indices.push_back(base); indices.push_back(base + k); indices.push_back(base + k + 1)

	out["verts"] = verts
	out["normals"] = normals
	out["uvs"] = uvs
	out["indices"] = indices
	out["count"] = verts.size()
	return out


## The offset s of the plane n.x = s, in the unit cube's own coordinates, with `fill` of the cube beneath it.
static func level_holding(n: Vector3, fill: float) -> float:
	var a: Vector3 = n.abs()
	# Reflect each axis the normal runs against: then the corner at the origin is the lowest.
	var shift: float = 0.0
	for i in 3:
		if n[i] < 0.0:
			shift += a[i]
	var lo: float = 0.0
	var hi: float = a.x + a.y + a.z
	for _k in 60:
		var mid: float = 0.5 * (lo + hi)
		if volume_below(a, mid) < fill:
			lo = mid
		else:
			hi = mid
	return 0.5 * (lo + hi) - shift


## Share of the unit cube with a.x <= s, for a normal `a` with no negative component: inclusion-exclusion over
## the corners the plane has passed, in as many dimensions as the normal has components.
static func volume_below(a: Vector3, s: float) -> float:
	var k: Array[float] = [a.x, a.y, a.z]
	k.sort()
	var tiny: float = 1.0e-9 * k[2]
	if k[1] <= tiny:
		return s / k[2]
	var dims: int = 2 if k[0] <= tiny else 3
	var sum: float = 0.0
	for corner in (1 << 3):
		if dims == 2 and (corner & 1) != 0:
			continue
		var reach: float = s
		var odd: bool = false
		for i in 3:
			if (corner >> i) & 1:
				reach -= k[i]
				odd = not odd
		if reach > 0.0:
			sum += (-1.0 if odd else 1.0) * pow(reach, float(dims))
	return sum / (2.0 * k[1] * k[2]) if dims == 2 else sum / (6.0 * k[0] * k[1] * k[2])


## Where the plane n.x = s crosses the unit cube's edges, ordered counter-clockwise seen from along `n`.
static func section(n: Vector3, s: float) -> PackedVector3Array:
	var pts: PackedVector3Array = PackedVector3Array()
	for axis in 3:
		if n[axis] == 0.0:
			continue
		var u: int = (axis + 1) % 3
		var v: int = (axis + 2) % 3
		for cu in 2:
			for cv in 2:
				var t: float = (s - n[u] * float(cu) - n[v] * float(cv)) / n[axis]
				if t < 0.0 or t > 1.0:
					continue
				var p: Vector3 = Vector3.ZERO
				p[u] = float(cu)
				p[v] = float(cv)
				p[axis] = t
				var seen: bool = false
				for known in pts:
					seen = seen or known.distance_squared_to(p) < 1.0e-18
				if not seen:
					pts.push_back(p)
	if pts.size() < 3:
		return PackedVector3Array()
	var mid: Vector3 = Vector3.ZERO
	for p in pts:
		mid += p
	mid /= float(pts.size())
	var e1: Vector3 = n.cross(Vector3.RIGHT if absf(n.x) < 0.9 * n.length() else Vector3.UP).normalized()
	var e2: Vector3 = n.normalized().cross(e1)
	var order: Array = []
	for p in pts:
		order.push_back([atan2((p - mid).dot(e2), (p - mid).dot(e1)), p])
	order.sort_custom(func(x: Array, y: Array) -> bool: return float(x[0]) < float(y[0]))
	var out: PackedVector3Array = PackedVector3Array()
	for e in order:
		out.push_back(e[1])
	return out
