class_name LAPoop
extends StaticBody3D

## Animal droppings left behind by a creature. Poop is a strong, persistent
## scent source: it repeatedly deposits the DEPOSITING ANIMAL'S species scent
## into the shared scent field, far stronger than the faint trail a moving
## creature leaves. Because the scent carries the depositor's species, any
## predator that follows scent will emergently track prey by their droppings --
## this is not special-cased here, it falls out of depositing the right species.
##
## Droppings also occasionally fertilize the soil: a few seconds after landing
## the poop emits `wants_seed` (~50% chance) so an ecology system can grow a new
## plant on the enriched patch (dung fertilizes).
##
## Built entirely in code, no external assets, no dependency on other project
## scripts. Robust against a null terrain / null scent field and guards against
## double queue_free.

signal wants_seed(world_pos: Vector3)

const LIFETIME: float = 90.0            # seconds until the dropping is gone
const SHRINK_DURATION: float = 12.0     # final seconds spent shrinking away
const DEPOSIT_INTERVAL: float = 0.5     # seconds between scent deposits
const BASE_STRENGTH: float = 4.0        # strong: ~4x a moving creature's trail
const SEED_DELAY: float = 6.0           # when the fertilize signal may fire
const SEED_CHANCE: float = 0.5          # probability the seed request is emitted

var _terrain: Object = null
var _scent: Object = null
var _species: String = "creature"

var _age: float = 0.0
var _deposit_timer: float = 0.0
var _seed_emitted: bool = false
var _dead: bool = false

# Cached so the shrink-out phase can scale relative to the built mesh.
var _mesh_instance: MeshInstance3D = null
var _base_scale: Vector3 = Vector3.ONE

func setup(terrain, scent, species: String) -> void:
	_terrain = terrain
	_scent = scent
	_species = species if species != "" else "creature"

	# Layer 2 keeps it pickable via the same layer-2 query other selectable
	# actors use; mask 0 means it never collides/pushes -- it just sits there.
	collision_layer = 2
	collision_mask = 0

	add_to_group("selectable")
	add_to_group("poop")
	add_to_group("scent_source")

	_build_mesh()
	_build_collision()

	_base_scale = scale
	_snap_to_terrain()

## A couple of small squashed brown lumps clustered together.
func _build_mesh() -> void:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = Color(0.28, 0.18, 0.10)
	material.roughness = 1.0
	material.metallic = 0.0

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "PoopMesh"
	add_child(_mesh_instance)

	# A small cluster of squashed spheres so it reads as a lumpy pile.
	var offsets: Array = [
		Vector3(0.0, 0.02, 0.0),
		Vector3(0.10, 0.05, 0.06),
		Vector3(-0.09, 0.04, -0.05),
	]
	var radii: Array = [0.14, 0.10, 0.09]

	for i in range(offsets.size()):
		var radius: float = float(radii[i])
		var lump_mesh: SphereMesh = SphereMesh.new()
		lump_mesh.radius = radius
		lump_mesh.height = radius * 2.0
		lump_mesh.material = material

		var lump: MeshInstance3D = MeshInstance3D.new()
		lump.name = "PoopLump%d" % i
		lump.mesh = lump_mesh
		lump.position = offsets[i]
		# Squash vertically so the pile sits low to the ground.
		lump.scale = Vector3(1.0, 0.55, 1.0)
		_mesh_instance.add_child(lump)

func _build_collision() -> void:
	var shape: SphereShape3D = SphereShape3D.new()
	shape.radius = 0.16
	var collision: CollisionShape3D = CollisionShape3D.new()
	collision.name = "PoopCollision"
	collision.shape = shape
	collision.position = Vector3(0.0, 0.08, 0.0)
	add_child(collision)

func _snap_to_terrain() -> void:
	if _terrain == null or not _terrain.has_method("surface_height"):
		return
	var height: float = _terrain.surface_height(global_position.x, global_position.z)
	if is_nan(height):
		return
	global_position.y = height

func get_inspector_payload() -> Dictionary:
	return {
		"title": "Droppings",
		"lines": [
			"From: %s" % _species,
			"A strong scent marker.",
			"Fertilizes the soil.",
		],
	}

func _physics_process(delta: float) -> void:
	if _dead:
		return

	_age += delta

	if _age >= LIFETIME:
		_free_once()
		return

	# Fade of scent output over the lifetime so an old dropping smells weaker.
	var life_fraction: float = clampf(_age / LIFETIME, 0.0, 1.0)
	var strength_scale: float = clampf(1.0 - life_fraction, 0.0, 1.0)

	# Deposit strong species scent periodically.
	_deposit_timer += delta
	if _deposit_timer >= DEPOSIT_INTERVAL:
		_deposit_timer -= DEPOSIT_INTERVAL
		_deposit_scent(strength_scale)

	# A few seconds after landing, occasionally request a plant here (dung
	# fertilizes the soil). Emitted at most once.
	if not _seed_emitted and _age >= SEED_DELAY:
		_seed_emitted = true
		if randf() < SEED_CHANCE:
			wants_seed.emit(global_position)

	# During the final SHRINK_DURATION seconds, shrink the pile away so it
	# visibly decomposes before it is removed.
	var shrink_start: float = LIFETIME - SHRINK_DURATION
	if _age >= shrink_start:
		var t: float = clampf((_age - shrink_start) / SHRINK_DURATION, 0.0, 1.0)
		var factor: float = clampf(1.0 - t, 0.05, 1.0)
		scale = _base_scale * factor

func _deposit_scent(strength_scale: float) -> void:
	if _scent == null or not _scent.has_method("deposit"):
		return
	var amount: float = BASE_STRENGTH * strength_scale
	if amount <= 0.0:
		return
	_scent.deposit(global_position, _species, amount)

func _free_once() -> void:
	if _dead:
		return
	_dead = true
	queue_free()
