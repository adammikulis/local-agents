class_name LARockMesh
extends RefCounted

# Shared factory for natural, irregular boulder meshes (NOT cubes). Used by ambient
# rocks, thrown rocks, and meteor debris so all stone in the world reads as real rock.
# A lat/long sphere is displaced per-vertex by 3D noise and squashed, then given flat
# (faceted) normals for a chiselled low-poly boulder look.

static func make(radius: float, seed_val: int, jitter: float = 0.42, rings: int = 7, segs: int = 9) -> ArrayMesh:
	var n: FastNoiseLite = FastNoiseLite.new()
	n.seed = seed_val
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.frequency = 0.9
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = 3

	# Build the displaced vertex grid.
	var grid: Array = []
	for i in range(rings + 1):
		var phi: float = float(i) / float(rings) * PI
		var row: Array = []
		for j in range(segs + 1):
			var theta: float = float(j) / float(segs) * TAU
			var dir: Vector3 = Vector3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
			var disp: float = 1.0 + jitter * n.get_noise_3d(dir.x * 2.0, dir.y * 2.0, dir.z * 2.0)
			var v: Vector3 = dir * radius * disp
			v.y *= 0.78                       # squash: boulders are wider than tall
			row.append(v)
		grid.append(row)

	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(rings):
		for j in range(segs):
			var a: Vector3 = grid[i][j]
			var b: Vector3 = grid[i + 1][j]
			var c: Vector3 = grid[i + 1][j + 1]
			var d: Vector3 = grid[i][j + 1]
			_facet(st, a, b, c)
			_facet(st, a, c, d)
	return st.commit()

static func _facet(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var nrm: Vector3 = (b - a).cross(c - a)
	if nrm.length() > 0.00001:
		nrm = nrm.normalized()
	else:
		nrm = Vector3.UP
	st.set_normal(nrm)
	st.add_vertex(a)
	st.set_normal(nrm)
	st.add_vertex(b)
	st.set_normal(nrm)
	st.add_vertex(c)

static func material(tint: Color = Color(0.42, 0.39, 0.36)) -> StandardMaterial3D:
	var m: StandardMaterial3D = StandardMaterial3D.new()
	m.albedo_color = tint
	m.roughness = 1.0
	m.metallic = 0.0
	return m
