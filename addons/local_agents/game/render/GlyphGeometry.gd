class_name LARenderGlyph

## Geometry every debug glyph in this layer is built from.


## A unit BoxMesh stretched to span `a` to `b` and `w` across, its local +Y running along the segment.
static func segment(a: Vector3, b: Vector3, w: float) -> Transform3D:
	var along: Vector3 = b - a
	var len_m: float = along.length()
	if len_m <= 0.0:
		return Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), a)
	var y: Vector3 = along / len_m
	var ref: Vector3 = Vector3.UP if absf(y.y) < 0.95 else Vector3.RIGHT
	var x: Vector3 = ref.cross(y).normalized()
	return Transform3D(Basis(x * w, y * len_m, y.cross(x) * w), 0.5 * (a + b))
