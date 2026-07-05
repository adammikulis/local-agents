class_name LAFish
extends CharacterBody3D

## A material-bound fish. It lives entirely inside the shared material field (LAWaterFieldSystem):
## it swims just under the surface, loosely schools with other fish, and turns back
## whenever it would leave the material. Nothing scripts where fish go — they simply stay in
## wet cells, so schools emergently form and follow wherever the material actually pools.
## Land predators (villagers/foxes) can catch fish that stray to the shallows.
## Built entirely in code, no external assets. (Explicit types only — no ':=' inferred typing.)

const GROUP_SELECTABLE: String = "selectable"
const GROUP_FISH: String = "fish"
const SPECIES_GROUP: String = "species_fish"

const SUBMERGE: float = 0.35          # how far below the material surface the fish swims
const SCHOOL_RADIUS: float = 6.0
const SCHOOL_WEIGHT: float = 0.8

var terrain = null                    # LAVoxelTerrainService (surface_height)
var material = null                      # LAWaterFieldSystem (is_water_at / surface_y_at)
var config: Dictionary = {}

var species: String = "fish"
var speed: float = 2.6
var size: float = 0.35
var color: Color = Color(0.62, 0.70, 0.82)
var sense_radius: float = 9.0
var maturity_age: float = 12.0
var food_value: float = 26.0
var max_age: float = 130.0

var age: float = 0.0
var state: String = "swim"
var _dying: bool = false

var _heading: Vector3 = Vector3.FORWARD
var _wander_timer: float = 0.0
var _mesh: MeshInstance3D = null


func setup(_terrain, _material, _config: Dictionary) -> void:
	terrain = _terrain
	material = _material
	config = _config.duplicate(true)
	species = String(config.get("species", species))
	speed = float(config.get("speed", speed))
	size = float(config.get("size", size))
	color = config.get("color", color)
	sense_radius = float(config.get("sense_radius", sense_radius))
	maturity_age = float(config.get("maturity_age", maturity_age))
	food_value = float(config.get("food_value", food_value))
	max_age = float(config.get("max_age", max_age))

	collision_layer = 2                # pickable via the same layer-2 query as other actors
	collision_mask = 0                 # movement is manual
	_build_body()
	add_to_group(GROUP_SELECTABLE)
	add_to_group(GROUP_FISH)
	add_to_group(SPECIES_GROUP)
	_heading = Vector3(randf() * 2.0 - 1.0, 0.0, randf() * 2.0 - 1.0).normalized()
	if _heading == Vector3.ZERO:
		_heading = Vector3.FORWARD


func _build_body() -> void:
	# A small flattened ellipsoid body (scaled sphere) plus a little tail fin.
	_mesh = MeshInstance3D.new()
	var body: SphereMesh = SphereMesh.new()
	body.radius = size
	body.height = size * 2.0
	body.radial_segments = 8
	body.rings = 4
	_mesh.mesh = body
	_mesh.scale = Vector3(0.7, 0.5, 1.5)      # slim, streamlined, longer front-to-back
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.4
	mat.metallic = 0.3                          # a little fishy sheen
	_mesh.material_override = mat
	add_child(_mesh)

	var tail: MeshInstance3D = MeshInstance3D.new()
	var fin: CylinderMesh = CylinderMesh.new()
	fin.top_radius = size * 0.7
	fin.bottom_radius = 0.0
	fin.height = size * 0.9
	fin.radial_segments = 3
	tail.mesh = fin
	tail.material_override = mat
	tail.position = Vector3(0.0, 0.0, -size * 1.4)
	tail.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	add_child(tail)

	var shape: CollisionShape3D = CollisionShape3D.new()
	var sph: SphereShape3D = SphereShape3D.new()
	sph.radius = maxf(size, 0.2)
	shape.shape = sph
	add_child(shape)


# A thrown rock / bite killed me, or I aged out.
func die(_cause: String = "", _impulse: Vector3 = Vector3.ZERO) -> void:
	# `_impulse` is accepted (and ignored) so a meteor's die(cause, impulse) call doesn't crash on fish.
	if _dying:
		return
	_dying = true
	if material != null and material.has_method("splash"):
		material.splash(global_position, 0.6)
	queue_free()


func on_struck() -> void:
	die("struck")


func is_mature() -> bool:
	return age >= maturity_age


func _physics_process(delta: float) -> void:
	if _dying:
		return
	age += delta
	if age >= max_age:
		die("old age")
		return
	if material == null:
		return

	var pos: Vector3 = global_position
	_wander_timer -= delta

	var desired: Vector3 = _heading
	if _wander_timer <= 0.0:
		_wander_timer = randf_range(1.0, 2.5)
		var jitter: Vector3 = Vector3(randf() * 2.0 - 1.0, 0.0, randf() * 2.0 - 1.0) * 0.7
		desired = _heading + jitter
	desired += _school_steer(pos)
	desired.y = 0.0

	# Test the step: if it would leave the material, steer back toward the nearest wet cell.
	var candidate: Vector3 = desired.normalized() if desired.length() > 0.001 else _heading
	var step_len: float = speed * delta
	var next_x: float = pos.x + candidate.x * step_len
	var next_z: float = pos.z + candidate.z * step_len
	if not material.is_water_at(next_x, next_z):
		var back: Vector3 = _find_water_dir(pos)
		if back != Vector3.ZERO:
			candidate = back
			state = "seek"
		else:
			candidate = -_heading         # no material found near: turn around
			state = "swim"
		next_x = pos.x + candidate.x * step_len
		next_z = pos.z + candidate.z * step_len
		# If even the corrective step is dry, hold position this frame (edge of a shrinking pool).
		if not material.is_water_at(next_x, next_z):
			next_x = pos.x
			next_z = pos.z
	else:
		state = "swim"

	_heading = candidate if candidate.length() > 0.001 else _heading

	# Ride just under the material surface (fall back to terrain if the query is momentarily NAN).
	var surf_y: float = material.surface_y_at(next_x, next_z)
	if is_nan(surf_y):
		var ground: float = float(terrain.surface_height(next_x, next_z)) if terrain != null and terrain.has_method("surface_height") else NAN
		if is_nan(ground):
			return
		surf_y = ground
	global_position = Vector3(next_x, surf_y - SUBMERGE, next_z)

	if _heading.length() > 0.01:
		var look: Vector3 = global_position + _heading
		if not look.is_equal_approx(global_position):
			look_at(look, Vector3.UP)


# Loose schooling with nearby fish: cohesion + alignment (same shared idea as creature
# flocking, kept local so fish stay independent of the land creatures).
func _school_steer(pos: Vector3) -> Vector3:
	var mates: Array = get_tree().get_nodes_in_group(SPECIES_GROUP)
	var center: Vector3 = Vector3.ZERO
	var align: Vector3 = Vector3.ZERO
	var n: int = 0
	for m in mates:
		if m == self or not is_instance_valid(m):
			continue
		var lm: LAFish = m as LAFish
		if lm == null:
			continue
		var d: float = pos.distance_to(lm.global_position)
		if d > SCHOOL_RADIUS or d < 0.0001:
			continue
		center += lm.global_position
		align += lm._heading
		n += 1
	if n == 0:
		return Vector3.ZERO
	center /= float(n)
	align /= float(n)
	var cohesion: Vector3 = center - pos
	cohesion.y = 0.0
	align.y = 0.0
	var steer: Vector3 = Vector3.ZERO
	if cohesion.length() > 0.001:
		steer += cohesion.normalized() * 0.5
	if align.length() > 0.001:
		steer += align.normalized() * 0.5
	return steer * SCHOOL_WEIGHT


# Probe rings for the nearest wet cell; return a flat unit heading toward it.
func _find_water_dir(pos: Vector3) -> Vector3:
	if material == null or not material.has_method("is_water_at"):
		return Vector3.ZERO
	var radii: Array = [size * 3.0, sense_radius, sense_radius * 2.0]
	var dirs: int = 10
	for r in radii:
		for k in range(dirs):
			var ang: float = TAU * float(k) / float(dirs)
			var px: float = pos.x + cos(ang) * float(r)
			var pz: float = pos.z + sin(ang) * float(r)
			if material.is_water_at(px, pz):
				var d: Vector3 = Vector3(px - pos.x, 0.0, pz - pos.z)
				if d.length() > 0.001:
					return d.normalized()
	return Vector3.ZERO


func get_inspector_payload() -> Dictionary:
	var stage: String = "adult" if is_mature() else "juvenile"
	return {
		"title": "Fish",
		"lines": [
			"Species: %s (%s)" % [species, stage],
			"Doing: %s" % ("swimming" if state == "swim" else "heading for material"),
			"Age: %.0fs / %.0fs" % [age, max_age],
			"Lives in material; caught at the shallows.",
		],
	}
