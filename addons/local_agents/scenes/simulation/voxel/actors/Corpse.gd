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
var _rot_overlay: StandardMaterial3D = null   # shared green->black decay tint
var _toppled: bool = false                    # gives the standing body a one-time nudge to fall over

## `display_model` is the dead creature's own visual node (its glTF model),
## handed off by Creature.die() so the corpse keeps the creature's real
## appearance instead of turning into a generic capsule. At the moment of
## death the model is left EXACTLY as it looked alive; it only visibly rots
## (tinting green, then black) over the decay lifetime. When display_model is
## null (creature had no model) we build the fallback capsule instead.
func setup(from_species: String, from_color: Color, from_size: float, terrain, display_model: Node3D = null) -> void:
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

	# One shared rot overlay drives the green->black decay across every mesh of
	# the body; it starts fully transparent so a fresh corpse looks untouched.
	_rot_overlay = _make_rot_overlay()

	if display_model != null:
		_adopt_model(display_model)
	else:
		_build_capsule_mesh(from_color, radius, height)

	# The physical body is always a simple capsule (robust, cheap) regardless of
	# whether the visual is the real model or a fallback capsule.
	var shape: CapsuleShape3D = CapsuleShape3D.new()
	shape.radius = radius
	shape.height = height
	_collision = CollisionShape3D.new()
	_collision.name = "CorpseCollision"
	_collision.shape = shape
	add_child(_collision)

	_base_scale = scale


# Reuse the dead creature's own model as the carcass, UNCHANGED at death: just
# stop its idle animation so it stays limp, and route the rot overlay onto its
# meshes so it can decay green->black over time.
func _adopt_model(model: Node3D) -> void:
	add_child(model)
	_freeze_animations(model)
	_apply_overlay(model, _rot_overlay)


# Fallback carcass for creatures that had no display model: a plain capsule
# using the creature's own colour, which then rots via the shared overlay.
func _build_capsule_mesh(from_color: Color, radius: float, height: float) -> void:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = from_color
	material.roughness = 1.0
	material.metallic = 0.0

	var mesh: CapsuleMesh = CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.material = material

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "CorpseMesh"
	_mesh_instance.mesh = mesh
	_mesh_instance.material_overlay = _rot_overlay
	add_child(_mesh_instance)


# A translucent overlay pass shared by every mesh of the body. Starts fully
# transparent (alpha 0) so death changes nothing; _update_rot() ramps its
# colour/alpha over the decay lifetime.
func _make_rot_overlay() -> StandardMaterial3D:
	var overlay: StandardMaterial3D = StandardMaterial3D.new()
	overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	overlay.albedo_color = Color(0.13, 0.32, 0.05, 0.0)
	overlay.roughness = 1.0
	overlay.metallic = 0.0
	return overlay


# Route the shared rot overlay onto every mesh under `node`.
func _apply_overlay(node: Node, mat: StandardMaterial3D) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).material_overlay = mat
	for child in node.get_children():
		_apply_overlay(child, mat)


# Halt any AnimationPlayers on the adopted model so the corpse stays limp
# rather than continuing to idle/breathe after death.
func _freeze_animations(node: Node) -> void:
	if node is AnimationPlayer:
		(node as AnimationPlayer).stop()
	for child in node.get_children():
		_freeze_animations(child)


# Drive the rot: fade a green tint in over the first stretch of decay, then
# lerp that green toward black as the body rots down to nothing.
func _update_rot() -> void:
	if _rot_overlay == null:
		return
	var t: float = clampf(_age / DECAY_LIFETIME, 0.0, 1.0)
	var green: Color = Color(0.13, 0.32, 0.05)
	var black: Color = Color(0.02, 0.02, 0.02)
	var col: Color = green.lerp(black, clampf((t - 0.35) / 0.65, 0.0, 1.0))
	col.a = clampf(t / 0.3, 0.0, 0.92)  # rot fades in over the first ~third
	_rot_overlay.albedo_color = col

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


# Unified food model: a carcass is MEAT — fresh ("dead") at first, then "decayed" (worth less) as it
# rots. Value is the meat still on it. (See LAFood — scavengers/carnivores eat it, herbivores don't.)
func food_profile() -> Dictionary:
	var st: String = "decayed" if _age > DECAY_LIFETIME * 0.4 else "dead"
	return {"type": "meat", "state": st, "value": _nutrition}

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

	# The body is spawned in the creature's upright pose, then topples on its
	# first physics tick: a sideways nudge lets gravity lay it down naturally.
	if not _toppled:
		_toppled = true
		var axis: Vector3 = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
		if axis.length() < 0.01:
			axis = Vector3.RIGHT
		angular_velocity = axis.normalized() * 3.0

	_age += delta
	_update_rot()

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
