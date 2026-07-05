class_name LACorpse
extends RigidBody3D

## The physical remains of a dead creature. Corpses do NOT vanish when a
## creature dies: they tip over onto their side as a darkened, desaturated
## body, can be flung by explosions (meteor impacts), serve as carrion that
## scavengers feed on, and slowly decay before finally disappearing.
##
## Built entirely in code, no external assets, no dependency on other project
## scripts. Robust against a null terrain and guards against double queue_free.

const DECAY_LIFETIME: float = 70.0        # seconds until fully decayed
const SHRINK_DURATION: float = 4.0        # final seconds spent shrinking away
const NUTRITION_PER_SIZE: float = 40.0    # carrion food value per unit of body size

var _species: String = "creature"
var _terrain: Object = null
var _nutrition: float = 0.0
var _size: float = 0.6
var _age: float = 0.0
var _dead: bool = false
var _scent = null                         # LAScentField (injected) — the carcass advertises itself
var _scent_cd: float = 0.0

# Cached so the shrink-out phase can scale relative to the built body.
var _mesh_instance: MeshInstance3D = null
var _collision: CollisionShape3D = null
var _base_scale: Vector3 = Vector3.ONE

func setup(from_species: String, from_color: Color, from_size: float, terrain) -> void:
	_species = from_species if from_species != "" else "creature"
	_terrain = terrain
	_size = maxf(from_size, 0.05)
	_nutrition = _size * NUTRITION_PER_SIZE

	# RigidBody so explosions can fling it; layer 2 keeps it pickable via the
	# same layer-2 query used by other selectable actors; mask 1 lets it rest
	# on the terrain.
	collision_layer = 2
	collision_mask = 1
	gravity_scale = 1.0

	add_to_group("corpse")
	add_to_group("selectable")
	add_to_group("carrion")

	var radius: float = _size * 0.6
	var height: float = maxf(_size * 2.0, radius * 2.0)  # capsule height must span the caps

	# Darkened + desaturated material so it clearly reads as a dead body.
	var dead_color: Color = from_color.darkened(0.35)
	var grey: Color = Color(0.35, 0.34, 0.33, dead_color.a)
	dead_color = dead_color.lerp(grey, 0.4)

	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = dead_color
	material.roughness = 1.0
	material.metallic = 0.0

	var mesh: CapsuleMesh = CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.material = material

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "CorpseMesh"
	_mesh_instance.mesh = mesh
	# Tip it onto its side (~90deg) so it lies down, plus a little yaw jitter.
	_mesh_instance.rotation = Vector3(
		PI * 0.5,
		randf_range(0.0, TAU),
		randf_range(-0.15, 0.15)
	)
	add_child(_mesh_instance)

	var shape: CapsuleShape3D = CapsuleShape3D.new()
	shape.radius = radius
	shape.height = height
	_collision = CollisionShape3D.new()
	_collision.name = "CorpseCollision"
	_collision.shape = shape
	_collision.rotation = _mesh_instance.rotation
	add_child(_collision)

	_base_scale = scale

## Launch the corpse outward (e.g. thrown by a meteor impact). Adds a random
## spin so it tumbles as it flies.
func fling(impulse: Vector3) -> void:
	if _dead:
		return
	apply_central_impulse(impulse)
	var spin: Vector3 = Vector3(
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0)
	) * (impulse.length() * 0.25 + 1.0)
	apply_torque_impulse(spin)

## Inject the shared scent field so the carcass advertises itself: scavengers smell it from afar
## and converge, which is the emergent basis for vultures gathering (and others "watching" them).
func set_scent(s) -> void:
	_scent = s


## A scavenger eats from the carcass. Reduces remaining nutrition by `amount`
## and returns the energy actually taken (clamped to what remained). When the
## carcass is used up it frees itself.
func feed(amount: float) -> float:
	if _dead:
		return 0.0
	var taken: float = clampf(amount, 0.0, _nutrition)
	_nutrition -= taken
	if _nutrition <= 0.0:
		_nutrition = 0.0
		_free_once()
	return taken

## Remaining food value in the carcass.
func nutrition() -> float:
	return _nutrition

func get_inspector_payload() -> Dictionary:
	return {
		"title": "Carcass",
		"lines": [
			"Dead %s" % _species,
			"Decaying...",
			"Carrion: %.0f left" % _nutrition,
		],
	}

func _physics_process(delta: float) -> void:
	if _dead:
		return

	_age += delta

	# Advertise the carcass as a decaying "carrion" scent scavengers follow from afar. Strength
	# tracks the meat left, so a fresh big kill smells strongest and fades as it is eaten/rots.
	if _scent != null and _scent.has_method("deposit"):
		_scent_cd -= delta
		if _scent_cd <= 0.0 and _nutrition > 0.0:
			_scent_cd = 1.2
			_scent.deposit(global_position, "carrion", clampf(_nutrition * 0.05, 0.4, 4.0))

	if _age >= DECAY_LIFETIME:
		_free_once()
		return

	# During the final SHRINK_DURATION seconds, shrink the body away so it
	# visibly wastes down to nothing before it is removed.
	var shrink_start: float = DECAY_LIFETIME - SHRINK_DURATION
	if _age >= shrink_start:
		var t: float = clampf((_age - shrink_start) / SHRINK_DURATION, 0.0, 1.0)
		var factor: float = clampf(1.0 - t, 0.05, 1.0)
		scale = _base_scale * factor

func _free_once() -> void:
	if _dead:
		return
	_dead = true
	queue_free()
