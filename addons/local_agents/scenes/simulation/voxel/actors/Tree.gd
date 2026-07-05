class_name LATree
extends StaticBody3D

## A natural-looking tree built entirely from code meshes (no external assets).
## A tapered brown trunk (CylinderMesh) plus a layered green canopy of overlapping
## foliage blobs. Per-tree seeded jitter in size / tilt / hue keeps a forest varied
## rather than cloned. Starts as a small sapling and grows to full size over ~20s.
##
## Species:
##   "oak" (default) -> rounded broadleaf, overlapping foliage spheres
##   "pine"          -> conical stacked cones, darker/taller/narrower
##
## Config keys (all optional):
##   "height":       float   base trunk height (units, ~3-7 typical)
##   "canopy_color": Color   foliage albedo (overrides species default)
##   "scale":        float   full-grown scale multiplier
##   "species":      String  "oak" | "pine"
##   "seed":         int     deterministic per-tree variation seed

const GROUP_SELECTABLE: String = "selectable"
const GROUP_TREE: String = "tree"

const GROW_TIME: float = 20.0        # seconds sapling -> full size
const START_FRACTION: float = 0.35   # freshly planted trees are visible immediately
const TOPPLE_TIME: float = 1.5       # seconds to fall flat
const TOPPLE_ANGLE: float = 1.483529 # ~85 degrees, avoids clipping through ground

var terrain = null             # terrain service exposing surface_height(x, z)
var config: Dictionary = {}

var species: String = "oak"
var trunk_height: float = 4.5
var canopy_color: Color = Color(0.18, 0.42, 0.16)
var trunk_color: Color = Color(0.32, 0.22, 0.13)
var max_scale: float = 1.0

var age: float = 0.0
var toppled: bool = false

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _tilt: float = 0.0               # small resting lean of the whole tree
var _upright_basis: Basis = Basis.IDENTITY
var _topple_axis: Vector3 = Vector3.RIGHT
var _topple_t: float = 0.0
var _topple_tween_active: bool = false


func setup(_terrain, _config: Dictionary = {}) -> void:
	terrain = _terrain
	config = _config.duplicate(true)

	species = String(config.get("species", species)).to_lower()
	if species != "pine" and species != "oak":
		species = "oak"

	# Deterministic per-tree variation.
	var seed_val: int = int(config.get("seed", randi()))
	_rng.seed = seed_val

	# Base trunk height: config, else a species-appropriate random range.
	if config.has("height"):
		trunk_height = maxf(float(config["height"]), 1.0)
	elif species == "pine":
		trunk_height = _rng.randf_range(5.0, 7.0)
	else:
		trunk_height = _rng.randf_range(3.0, 5.5)

	max_scale = maxf(float(config.get("scale", max_scale)), 0.05)

	# Species foliage defaults, then optional override, then small hue jitter.
	if species == "pine":
		canopy_color = Color(0.12, 0.32, 0.14)   # darker evergreen
	else:
		canopy_color = Color(0.18, 0.42, 0.16)
	if config.has("canopy_color"):
		canopy_color = config["canopy_color"]
	canopy_color = _jitter_hue(canopy_color)
	trunk_color = _jitter_hue(Color(0.32, 0.22, 0.13), 0.03)

	# Slight resting lean so a stand of trees doesn't look regimented.
	_tilt = _rng.randf_range(-0.06, 0.06)

	collision_layer = 2
	collision_mask = 0
	add_to_group(GROUP_SELECTABLE)
	add_to_group(GROUP_TREE)

	_build_trunk()
	if species == "pine":
		_build_pine_canopy()
	else:
		_build_broadleaf_canopy()
	_build_collision()

	_apply_resting_tilt()
	_snap_to_surface()
	_apply_growth()


func _jitter_hue(base: Color, amount: float = 0.05) -> Color:
	var h: float = base.h + _rng.randf_range(-amount, amount)
	var s: float = clampf(base.s + _rng.randf_range(-0.06, 0.06), 0.0, 1.0)
	var v: float = clampf(base.v + _rng.randf_range(-0.08, 0.08), 0.0, 1.0)
	return Color.from_hsv(fposmod(h, 1.0), s, v, base.a)


func _make_material(col: Color) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.95
	mat.metallic = 0.0
	return mat


func _build_trunk() -> void:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	mesh.name = "Trunk"
	var trunk: CylinderMesh = CylinderMesh.new()
	var bottom: float = lerpf(0.22, 0.42, clampf(trunk_height / 7.0, 0.0, 1.0))
	trunk.bottom_radius = bottom
	trunk.top_radius = bottom * 0.55       # taper: top narrower than bottom
	trunk.height = trunk_height
	trunk.radial_segments = 8
	mesh.mesh = trunk
	mesh.position = Vector3(0.0, trunk_height * 0.5, 0.0)
	mesh.material_override = _make_material(trunk_color)
	add_child(mesh)


func _build_broadleaf_canopy() -> void:
	# 2-4 overlapping spheres clustered at the crown for a rounded, natural look.
	var blobs: int = _rng.randi_range(3, 4)
	var crown: float = trunk_height
	var base_r: float = maxf(trunk_height * 0.34, 0.9)
	var mat: StandardMaterial3D = _make_material(canopy_color)
	for i in range(blobs):
		var blob: MeshInstance3D = MeshInstance3D.new()
		blob.name = "Foliage%d" % i
		var ball: SphereMesh = SphereMesh.new()
		var r: float = base_r * _rng.randf_range(0.7, 1.05)
		ball.radius = r
		ball.height = r * 2.0
		ball.radial_segments = 10
		ball.rings = 6
		blob.mesh = ball
		# First blob centred on the crown; the rest offset around/above it.
		var off: Vector3 = Vector3.ZERO
		if i > 0:
			off = Vector3(
				_rng.randf_range(-base_r * 0.6, base_r * 0.6),
				_rng.randf_range(-base_r * 0.1, base_r * 0.5),
				_rng.randf_range(-base_r * 0.6, base_r * 0.6))
		blob.position = Vector3(0.0, crown + base_r * 0.4, 0.0) + off
		blob.material_override = mat
		add_child(blob)


func _build_pine_canopy() -> void:
	# Stacked cones tapering upward for a conical evergreen silhouette.
	var tiers: int = _rng.randi_range(3, 4)
	var mat: StandardMaterial3D = _make_material(canopy_color)
	var base_r: float = maxf(trunk_height * 0.3, 0.8)
	var tier_h: float = trunk_height * 0.42
	var start_y: float = trunk_height * 0.55
	for i in range(tiers):
		var frac: float = float(i) / float(tiers)
		var cone: MeshInstance3D = MeshInstance3D.new()
		cone.name = "Cone%d" % i
		var mesh: CylinderMesh = CylinderMesh.new()
		mesh.top_radius = 0.0
		mesh.bottom_radius = base_r * (1.0 - frac * 0.7)
		mesh.height = tier_h
		mesh.radial_segments = 8
		cone.mesh = mesh
		cone.position = Vector3(0.0, start_y + frac * (trunk_height * 0.75) + tier_h * 0.5, 0.0)
		cone.material_override = mat
		add_child(cone)


func _build_collision() -> void:
	var shape: CollisionShape3D = CollisionShape3D.new()
	shape.name = "TrunkCollision"
	var cyl: CylinderShape3D = CylinderShape3D.new()
	cyl.radius = maxf(trunk_height * 0.12, 0.3)
	cyl.height = trunk_height
	shape.shape = cyl
	shape.position = Vector3(0.0, trunk_height * 0.5, 0.0)
	add_child(shape)


func _apply_resting_tilt() -> void:
	# Store the upright orientation (with lean) so topple can rotate from it.
	_upright_basis = Basis(Vector3.FORWARD, _tilt)
	transform.basis = _upright_basis


func _snap_to_surface() -> void:
	if terrain == null or not terrain.has_method("surface_height"):
		return
	var y = terrain.surface_height(global_position.x, global_position.z)
	if typeof(y) != TYPE_FLOAT and typeof(y) != TYPE_INT:
		return
	var yf: float = float(y)
	if is_nan(yf) or is_inf(yf):
		return
	var pos: Vector3 = global_position
	pos.y = yf
	global_position = pos


func _physics_process(delta: float) -> void:
	if toppled:
		# The Tween (if any) drives the fall; otherwise lerp it here.
		if not _topple_tween_active:
			_advance_topple(delta)
		return
	age += delta
	_apply_growth()


func _grown_fraction() -> float:
	return clampf(age / GROW_TIME, START_FRACTION, 1.0)


func _apply_growth() -> void:
	scale = Vector3.ONE * (_grown_fraction() * max_scale)


func _advance_topple(delta: float) -> void:
	_topple_t = minf(_topple_t + delta / TOPPLE_TIME, 1.0)
	var eased: float = ease(_topple_t, 2.2)   # accelerate as it falls
	var fall: Basis = Basis(_topple_axis, eased * TOPPLE_ANGLE)
	transform.basis = fall * _upright_basis


func get_inspector_payload() -> Dictionary:
	var title: String = "%s Tree" % species.capitalize()
	var status: String = "toppled" if toppled else ("mature" if _grown_fraction() >= 1.0 else "growing")
	return {
		"title": title,
		"lines": [
			"Species: %s" % species,
			"Height: %.1fm" % (trunk_height * max_scale),
			"Age: %.1fs (%s)" % [age, status],
			"Growth: %d%%" % int(_grown_fraction() * 100.0),
		],
	}


func topple(direction: Vector3) -> void:
	if toppled:
		return
	toppled = true
	# Rotate about the horizontal axis perpendicular to the fall direction.
	var dir: Vector3 = Vector3(direction.x, 0.0, direction.z)
	if dir.length() < 0.001:
		dir = Vector3(_rng.randf_range(-1.0, 1.0), 0.0, _rng.randf_range(-1.0, 1.0))
		if dir.length() < 0.001:
			dir = Vector3.RIGHT
	dir = dir.normalized()
	# Axis is perpendicular to fall direction and to up, so the crown swings
	# toward `direction`.
	_topple_axis = Vector3.UP.cross(dir).normalized()
	if _topple_axis.length() < 0.001:
		_topple_axis = Vector3.RIGHT
	_topple_t = 0.0

	# Animate via Tween if we are inside a tree; otherwise _physics_process lerps.
	if is_inside_tree():
		_topple_tween_active = true
		var tween: Tween = create_tween()
		tween.tween_method(_set_topple_progress, 0.0, 1.0, TOPPLE_TIME)
		tween.tween_callback(func() -> void: _topple_tween_active = false)


func _set_topple_progress(t: float) -> void:
	_topple_t = clampf(t, 0.0, 1.0)
	var eased: float = ease(_topple_t, 2.2)
	var fall: Basis = Basis(_topple_axis, eased * TOPPLE_ANGLE)
	transform.basis = fall * _upright_basis
