class_name LAFieldBoxOutline
extends Node3D

## THE SIMULATED BOX WHERE IT MEETS THE WORLD: its four ground edges laid along the relief they cross,
## and a pillar rising from each corner that fades out with height. The top edges are not drawn.

const OutlineShader: Shader = preload("res://addons/local_agents/game/render/FieldBoxOutline.gdshader")

## Edge girth as a fraction of the distance from the eye: a fixed angular thickness, so the box reads the
## same standing inside it and from orbit.
const EDGE_SUBTEND: float = 0.006
## Fade length as a fraction of the footprint's shorter horizontal span. A length in metres would be one
## number for boxes whose footprints differ by kilometres.
const FADE_FOOTPRINT_FRAC: float = 0.25
## What is left of a pillar's glow at the fade height: a twentieth of its foot, and gone.
const FADE_ALPHA_FLOOR: float = 0.05
## Pieces per ground edge: the line follows the relief instead of cutting through it.
const GROUND_PIECES: int = 48
## Pieces per pillar, each sized at its own distance from the eye and shaded over its own span.
const PILLAR_PIECES: int = 24
## Fractions of the fade height a pillar is published at: its lit end first, the fade height last.
const PILLAR_AT: Array = [0.05, 0.15, 0.25, 0.5, 0.75, 1.0]
## Published ground vertices: every stride-th sample of the drawn line.
const PUBLISH_STRIDE: int = 4

const EDGES: int = 4
const SHOOT_FLAG: String = "--shoot="

var _f = null
var _terrain = null
var _camera: Camera3D = null
var _body: Node3D = null
var _centre: Vector3 = Vector3.ZERO
var _fade_m: float = 0.0
var _mm: MultiMesh = null
var _profiled: bool = false
var _absent: bool = false
var _publish: bool = false
## Ground samples in the body's frame: EDGES runs of GROUND_PIECES + 1 points.
var _ground: PackedVector3Array = PackedVector3Array()
var _corners: PackedVector3Array = PackedVector3Array()
var _ups: PackedVector3Array = PackedVector3Array()


## The outline for the box `field` was laid on. Draws nothing when that world has no box.
static func build(field, terrain, camera: Camera3D, body: Node3D) -> LAFieldBoxOutline:
	var node: LAFieldBoxOutline = LAFieldBoxOutline.new()
	node.setup(field, terrain, camera, body)
	return node


func setup(field, terrain, camera: Camera3D, body: Node3D) -> void:
	name = "FieldBoxOutline"
	_f = field
	_terrain = terrain
	_camera = camera
	_body = body
	var box: AABB = LARenderLayer.slice_body_aabb(field, body)
	visible = box.size.length() > 0.0 and terrain != null and terrain.has_method("body_surface_radius")
	set_process(visible)
	if not visible:
		return
	_centre = field.centre()
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = BoxMesh.new()
	_mm.instance_count = EDGES * (GROUND_PIECES + PILLAR_PIECES)
	_mm.visible_instance_count = 0
	var view: MultiMeshInstance3D = MultiMeshInstance3D.new()
	view.name = "Edges"
	view.multimesh = _mm
	view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = OutlineShader
	view.material_override = mat
	add_child(view)
	for arg in OS.get_cmdline_user_args():
		if String(arg).begins_with(SHOOT_FLAG):
			_publish = true


func _process(_delta: float) -> void:
	if not visible or _f == null or _camera == null or not is_instance_valid(_camera):
		return
	if not _profiled and not _read_ground():
		return
	var frame: Basis = _f._body_basis
	global_transform = Transform3D(frame, _centre - frame * _centre)
	var eye: Vector3 = _f.point_to_field(_camera.global_position)
	var n: int = 0
	for e in EDGES:
		var run: int = e * (GROUND_PIECES + 1)
		for k in GROUND_PIECES:
			var a: Vector3 = _ground[run + k]
			var b: Vector3 = _ground[run + k + 1]
			var mid: Vector3 = 0.5 * (a + b)
			var w: float = EDGE_SUBTEND * eye.distance_to(mid)
			# Proud of the ground by its own girth, or the line lies in the surface and z-fights it.
			var lift: Vector3 = (mid - _centre).normalized() * w
			_mm.set_instance_transform(n, LARenderGlyph.segment(a + lift, b + lift, w))
			_mm.set_instance_custom_data(n, Color(1.0, 1.0, 0.0, 0.0))
			n += 1
	for c in EDGES:
		var base: Vector3 = _corners[c]
		var up: Vector3 = _ups[c]
		for k in PILLAR_PIECES:
			var t0: float = float(k) / float(PILLAR_PIECES)
			var t1: float = float(k + 1) / float(PILLAR_PIECES)
			var a2: Vector3 = base + up * (t0 * _fade_m)
			var b2: Vector3 = base + up * (t1 * _fade_m)
			var w2: float = EDGE_SUBTEND * eye.distance_to(0.5 * (a2 + b2))
			_mm.set_instance_transform(n, LARenderGlyph.segment(a2, b2, w2))
			_mm.set_instance_custom_data(n, Color(_fade(t0), _fade(t1), 0.0, 0.0))
			n += 1
	_mm.visible_instance_count = n
	if _publish:
		_report()


## Glow along a pillar: full at the ground, zero at the fade height.
static func _fade(t: float) -> float:
	return 1.0 - smoothstep(0.0, 1.0, clampf(t, 0.0, 1.0))


## The footprint walked over the body's own surface. False while the terrain has no radius to give: the
## ground under an edge is measured, never assumed flat.
func _read_ground() -> bool:
	var box: AABB = LARenderLayer.slice_body_aabb(_f, _body)
	var radial: Vector3 = (box.get_center() - _centre).normalized()
	var up_axis: int = LAFieldGeometry.slot_toward(radial) >> 1
	var h: PackedInt32Array = PackedInt32Array()
	for i in 3:
		if i != up_axis:
			h.append(i)
	if h.size() != 2:
		return false
	_fade_m = FADE_FOOTPRINT_FRAC * minf(box.size[h[0]], box.size[h[1]])
	# The four horizontal corners of the box, walked as a loop.
	var loop: PackedVector3Array = PackedVector3Array()
	for step in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1)]:
		var p: Vector3 = box.get_center()
		p[h[0]] = box.position[h[0]] + float(step.x) * box.size[h[0]]
		p[h[1]] = box.position[h[1]] + float(step.y) * box.size[h[1]]
		loop.append(p)
	var ground: PackedVector3Array = PackedVector3Array()
	var corners: PackedVector3Array = PackedVector3Array()
	var ups: PackedVector3Array = PackedVector3Array()
	for e in EDGES:
		var a: Vector3 = loop[e]
		var b: Vector3 = loop[(e + 1) % EDGES]
		for k in range(GROUND_PIECES + 1):
			var dir: Vector3 = (a.lerp(b, float(k) / float(GROUND_PIECES)) - _centre).normalized()
			var r: float = float(_terrain.body_surface_radius(dir))
			if not is_finite(r) or r <= 0.0:
				if not _absent:
					_absent = true
					print("BOX_OUTLINE_ABSENT=%s" % JSON.stringify(
						{"reason": "the body reports no surface radius under the box footprint"}))
				return false
			ground.append(_centre + dir * r)
			if k == 0:
				corners.append(_centre + dir * r)
				ups.append(dir)
	_ground = ground
	_corners = corners
	_ups = ups
	_profiled = true
	return true


## Where the outline stands in the picture this run is about to take: the ground line as four runs of
## pixels, and each pillar's lit end and faded top, so a photograph can be held to it. A vertex behind
## the eye publishes null rather than a projection that means nothing.
func _report() -> void:
	var size: Vector2 = _camera.get_viewport().get_visible_rect().size
	var line: Array = []
	for e in EDGES:
		var run: int = e * (GROUND_PIECES + 1)
		var edge: Array = []
		for k in range(0, GROUND_PIECES + 1, PUBLISH_STRIDE):
			var px: Array = _pixel(_ground[run + k])
			edge.append(null if px.is_empty() else px)
		line.append(edge)
	var pillars: Array = []
	for c in EDGES:
		var run: Array = []
		for t in PILLAR_AT:
			var px: Array = _pixel(_corners[c] + _ups[c] * (float(t) * _fade_m))
			run.append(null if px.is_empty() else px)
		pillars.append(run)
	print("BOX_OUTLINE=%s" % JSON.stringify({
		"size": [int(size.x), int(size.y)],
		"thick_px": EDGE_SUBTEND * size.y / (2.0 * tan(0.5 * deg_to_rad(_camera.fov))),
		"fade_m": _fade_m, "fade_floor": FADE_ALPHA_FLOOR, "pillar_at": PILLAR_AT,
		"ground": line, "pillars": pillars}))


## A field-frame point in the shot's pixels; empty when it stands behind the eye.
func _pixel(field_pos: Vector3) -> Array:
	var world: Vector3 = _f.field_to_point(field_pos)
	if _camera.is_position_behind(world):
		return []
	var p: Vector2 = _camera.unproject_position(world)
	return [snappedf(p.x, 0.1), snappedf(p.y, 0.1)]
