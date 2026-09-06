class_name LAFieldVectors
extends MultiMeshInstance3D

## ONE ARROW GLYPH PER OPEN FIELD CELL, aimed along a vector field THE WORLD ACTUALLY CONTAINS: the
## cell's velocity, or the gravity solved at it. A world holding neither draws nothing.

const ArrowShader: Shader = preload("res://addons/local_agents/game/render/FieldArrow.gdshader")

## UNSET takes the highest field the world's own processes produce; OFF says this world draws no glyphs
## and outranks the game shell's --vectors flag.
const SOURCE_UNSET: String = "unset"
const SOURCE_OFF: String = "off"
const SOURCE_WIND: String = "wind"
const SOURCE_GRAVITY: String = "gravity"

## The process record each source reads off. No record, no field, no glyph.
const GRAVITY_PASS: String = "GravityPass.gd"
const MOMENTUM_TRANSPORT: String = "mom_flux"

## PRESENTATION SCALE for the wind ramp, m/s: a jet stream. At it the glyph is full length and the ramp
## is saturated. The gravity ramp has no constant: it saturates at the largest |g| among the glyphs this
## rebuild drew, which the legend prints, so nothing stands in for a magnitude nobody measured.
const WIND_REF_M_S: float = 70.0

## THE GLYPH IS DRAWN AT A FIXED ANGLE, radians: a quiver reads the same from a metre up and from orbit,
## and cell-sized arrows are a wall of fill from anywhere inside the box.
const GLYPH_SUBTEND_RAD: float = 0.05
## THE SAMPLE IS A LATTICE ABOUT THE EYE, this many points on a side, spaced at a fraction of the eye's
## own height over the body. Every cell of a graded box is millions of glyphs and a walk nobody affords;
## what is asked for instead is the field where the viewer is standing, at the density it reads at.
const LATTICE_SIDE: int = 15
const LATTICE_SPACING_FRAC: float = 0.25
const REBUILD_PERIOD: float = 0.22
const RECENTER_DOT: float = 0.999
## Glyph girth as a fraction of its own length: an arrow's head is a quarter of the arrow.
const THICK_FRAC: float = 1.25
const STRIPES: int = 6

## Which vector field the glyphs draw: "wind", "gravity", or "off".
var source: String = SOURCE_OFF

var _f = null
var _camera: Node3D = null
var _centre: Vector3 = Vector3.ZERO
var _sea_radius: float = 0.0
var _mm: MultiMesh = null
var _mat: ShaderMaterial = null
var _accum: float = REBUILD_PERIOD
var _last_radial: Vector3 = Vector3.ZERO
var _ref: float = 0.0
var _drawn: int = 0
var _capacity: int = 0


func setup(field, camera: Node3D, centre: Vector3, sea_radius: float) -> void:
	_f = field
	_camera = camera
	_centre = centre
	_sea_radius = sea_radius
	name = "FieldVectors"
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = _arrow_mesh()
	_mm.instance_count = 0
	multimesh = _mm
	_mat = ShaderMaterial.new()
	_mat.shader = ArrowShader
	_mat.set_shader_parameter("stripes", STRIPES)
	material_override = _mat
	_apply_source()


## The vector field drawn. UNSET takes the highest this world holds; a source the world does not contain
## is refused, once and out loud, and nothing stands in for it.
func set_source(want: String) -> void:
	source = want
	if want != SOURCE_OFF:
		var pick: String = highest_source() if want == SOURCE_UNSET else want
		if pick == SOURCE_OFF or not has_source(pick):
			print("FIELD_VECTORS_ABSENT=%s" % JSON.stringify(
				{"source": "any" if want == SOURCE_UNSET else want, "rung": LAProcessSet.active()}))
			pick = SOURCE_OFF
		source = pick
	_apply_source()


## Whether this world's processes produce `want` at all. Gravity is solved by GravityPass; a velocity
## exists only where momentum is transported.
static func has_source(want: String) -> bool:
	if want == SOURCE_GRAVITY:
		return LAProcessSet.has_record("pass", GRAVITY_PASS)
	if want == SOURCE_WIND:
		return LAProcessSet.has_record("transport", MOMENTUM_TRANSPORT)
	return false


## The richest field this world holds: wind where matter moves, gravity where it only pulls, else none.
static func highest_source() -> String:
	if has_source(SOURCE_WIND):
		return SOURCE_WIND
	return SOURCE_GRAVITY if has_source(SOURCE_GRAVITY) else SOURCE_OFF


## The magnitude the ramp saturates at, in the source's own unit. 0 when the source names nothing this
## world can measure — and then no glyph is drawn.
func reference() -> float:
	return _ref


## The source's unit, for the legend.
func unit() -> String:
	return "m/s" if source == SOURCE_WIND else ("m/s²" if source == SOURCE_GRAVITY else "")


## Glyphs standing in the last built frame. LAVoxelHarness publishes it beside the shot.
func drawn() -> int:
	return _drawn


func _apply_source() -> void:
	_ref = WIND_REF_M_S if source == SOURCE_WIND else 0.0
	visible = source != SOURCE_OFF
	set_process(visible)
	if not visible:
		_drawn = 0
		if _mm != null:
			_mm.visible_instance_count = 0
		return
	if _ref > 0.0:
		_mat.set_shader_parameter("v_ref", _ref)
	_accum = REBUILD_PERIOD


func _process(delta: float) -> void:
	if _f == null or _camera == null or not is_instance_valid(_camera):
		return
	# THE LATTICE IS LAID IN THE BODY'S FRAME. The glyphs are built from the grid's own cell centres and
	# vectors, so the node carries the field -> world map and the eye comes the other way through it.
	var frame: Basis = _f._body_basis
	global_transform = Transform3D(frame, _centre - frame * _centre)
	var cam_pos: Vector3 = _f.point_to_field(_camera.global_position)
	var radial: Vector3 = (cam_pos - _centre).normalized()
	_accum += delta
	if _accum < REBUILD_PERIOD and _last_radial.dot(radial) > RECENTER_DOT:
		return
	_accum = 0.0
	_last_radial = radial
	_rebuild(cam_pos, radial)


func _rebuild(cam_pos: Vector3, _radial: Vector3) -> void:
	var grid = _f._grid
	if grid == null:
		return
	var n: int = int(grid.cell_count)
	var solid: PackedByteArray = _f._solid
	var centres: PackedVector3Array = grid.centres
	if solid.size() != n or centres.size() != n:
		return
	var wind: bool = source == SOURCE_WIND
	if wind and not _f._mirrors.has("vel_x"):
		return
	# The lattice about the eye, in the grid's own frame, spaced off the eye's height over the body.
	var alt: float = maxf((cam_pos - _centre).length() - _sea_radius, 1.0)
	# Never coarser than the grid's own coarse cell, or the lattice steps over whole cells of it.
	var spacing: float = minf(LATTICE_SPACING_FRAC * alt, float(grid.cell_size))
	var half: int = LATTICE_SIDE / 2
	var seen: Dictionary = {}
	# THE EYE'S OWN CELL IS NOT DRAWN: the eye stands inside that glyph rather than looking at it, and a
	# glyph subtending a fixed angle at no distance covers the frame.
	seen[grid.cell_at(cam_pos)] = true
	var picked: PackedInt32Array = PackedInt32Array()
	var vecs: PackedVector3Array = PackedVector3Array()
	var ref: float = 0.0
	for ix in range(-half, half + 1):
		for iy in range(-half, half + 1):
			for iz in range(-half, half + 1):
				var at: Vector3 = cam_pos + Vector3(ix, iy, iz) * spacing
				var c: int = grid.cell_at(at)
				if c < 0 or seen.has(c) or solid[c] != 0:
					continue
				seen[c] = true
				var v: Vector3 = _vector_at(c, wind)
				var mag: float = v.length()
				if mag <= 0.0:
					continue           # nothing to aim a glyph along; an arrow there would be invented
				picked.append(c)
				vecs.append(v)
				ref = maxf(ref, mag)
	# The ramp's own top: the wind's declared jet, or the largest field magnitude actually drawn.
	if _ref <= 0.0 or not wind:
		_ref = ref
	_drawn = 0
	visible = _ref > 0.0
	if not visible:
		_mm.visible_instance_count = 0
		return
	_mat.set_shader_parameter("v_ref", _ref)
	var alt_span: float = 1.0
	var xforms: Array = []
	var customs: Array = []
	for i in picked.size():
		var c2: int = picked[i]
		var v2: Vector3 = vecs[i]
		var mag2: float = v2.length()
		var pos2: Vector3 = centres[c2]
		var span: float = GLYPH_SUBTEND_RAD * cam_pos.distance_to(pos2)
		var frac: float = minf(mag2 / _ref, 1.0)
		var alt_c: float = (pos2 - _centre).length() - _sea_radius
		alt_span = maxf(alt_span, absf(alt_c))
		xforms.append(Transform3D(_aim(v2, mag2, span * THICK_FRAC, span * frac), pos2))
		# A stable per-cell stripe offset, so a lattice of equal glyphs does not march in lockstep.
		customs.append(Color(mag2, float(c2 % 97) / 97.0, maxf(alt_c, 0.0), span * frac))
	_drawn = xforms.size()
	_mat.set_shader_parameter("alt_fade_m", alt_span)
	if _drawn > _capacity:
		_capacity = _drawn
		_mm.instance_count = _capacity
	for i in _drawn:
		_mm.set_instance_transform(i, xforms[i])
		_mm.set_instance_custom_data(i, customs[i])
	_mm.visible_instance_count = _drawn


func _vector_at(c: int, wind: bool) -> Vector3:
	if wind:
		return _f._mirrors.vec3("vel_x", "vel_y", "vel_z", c)
	return _f._gravity.g_vec_at(c) if _f._gravity != null else Vector3.ZERO


## A basis whose +Z runs along `v`, girth `w`, length `l`. Only a cell with flow reaches here.
func _aim(v: Vector3, mag: float, w: float, l: float) -> Basis:
	var z: Vector3 = v / mag
	var ref: Vector3 = Vector3.UP if absf(z.y) < 0.95 else Vector3.RIGHT
	var x: Vector3 = ref.cross(z).normalized()
	return Basis(x * w, z.cross(x) * w, z * l)


## A unit arrow along +Z: a square shaft and a four-sided head, the tip at z = 1.
static func _arrow_mesh() -> ArrayMesh:
	const SHAFT_R: float = 0.035
	const HEAD_R: float = 0.10
	const HEAD_Z: float = 0.72
	var ring: Array = [Vector2(1.0, 1.0), Vector2(-1.0, 1.0), Vector2(-1.0, -1.0), Vector2(1.0, -1.0)]
	var v: PackedVector3Array = PackedVector3Array()
	for i in 4:
		var a: Vector2 = ring[i] * SHAFT_R
		var b: Vector2 = ring[(i + 1) % 4] * SHAFT_R
		var a3: Vector3 = Vector3(a.x, a.y, 0.0)
		var b3: Vector3 = Vector3(b.x, b.y, 0.0)
		var at: Vector3 = Vector3(a.x, a.y, HEAD_Z)
		var bt: Vector3 = Vector3(b.x, b.y, HEAD_Z)
		v.append_array([a3, b3, bt, a3, bt, at])
		var ha: Vector2 = ring[i] * HEAD_R
		var hb: Vector2 = ring[(i + 1) % 4] * HEAD_R
		v.append_array([Vector3(ha.x, ha.y, HEAD_Z), Vector3(hb.x, hb.y, HEAD_Z), Vector3(0.0, 0.0, 1.0)])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	var m: ArrayMesh = ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
