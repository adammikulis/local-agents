class_name LANest
extends Node3D

## A creature's home site. The shelter varies by species so each kind of animal
## builds its own recognisable home: a bird weaves a twig cup up in a tree, a
## rabbit digs a burrow, a fox digs a larger den, a villager raises a hut, and
## anything else gets a generic earthen mound. A nest tracks the young raised
## there and slowly falls into disrepair when its owners stop visiting -- unused
## nests eventually rot away.
##
## Built entirely in code, no external assets, no dependency on other project
## scripts. Robust against a null terrain and guards against double queue_free.

const IDLE_TIMEOUT: float = 120.0        # seconds of neglect before the nest rots away
const DISREPAIR_START: float = 60.0      # idle seconds after which condition visibly degrades

var terrain: Object = null               # LAVoxelTerrainService (injected), may be null
var species: String = "creature"
var owner_family: int = -1
var in_tree: bool = false

var _young: int = 0
var _age: float = 0.0                     # total lifetime, only ever grows
var _idle: float = 0.0                    # seconds since the last touch()
var _dead: bool = false

var _mesh_root: MeshInstance3D = null


func setup(from_terrain, from_species: String, from_owner_family: int, from_in_tree: bool) -> void:
	terrain = from_terrain
	species = from_species if from_species != "" else "creature"
	owner_family = from_owner_family
	in_tree = from_in_tree

	add_to_group("nest")
	add_to_group("selectable")

	# An in-tree caller always gets the elevated woven cup regardless of species.
	# Otherwise the shelter form is chosen from the species so mammals build their
	# own kind of home.
	if in_tree:
		_build_twig_cup()
	else:
		match species:
			"bird":
				# A ground-nesting bird still weaves a cup, just resting on the soil.
				_build_twig_cup()
			"rabbit":
				_build_burrow()
			"fox":
				_build_den()
			"villager":
				_build_hut()
			_:
				_build_earthen_mound()
		_snap_to_terrain()
		_orient_radial()

	# A layer-2 pick collider so the player's selection raycast (VoxelWorld
	# ._select_at, which collides with bodies) can hit the shelter. Added after
	# the mesh is built so it is sized to match the shelter that was chosen.
	_add_picker()


## Add the pick-only physics body used for selection. It sits on collision
## layer 2 (the pick layer) with mask 0 so it never participates in the
## simulation's physics -- it exists purely for the click raycast. The sphere
## is sized/centred to roughly cover the built shelter's visual extents.
func _add_picker() -> void:
	var pick_radius: float = 0.6
	var pick_center_y: float = 0.12
	if in_tree:
		pick_radius = 0.35
		pick_center_y = 0.10
	else:
		match species:
			"bird":
				pick_radius = 0.35
				pick_center_y = 0.10
			"rabbit":
				pick_radius = 0.55
				pick_center_y = 0.12
			"fox":
				pick_radius = 0.78
				pick_center_y = 0.14
			"villager":
				pick_radius = 0.72
				pick_center_y = 0.40
			_:
				pick_radius = 0.60
				pick_center_y = 0.12

	var body: StaticBody3D = StaticBody3D.new()
	body.name = "NestPicker"
	body.collision_layer = 2
	body.collision_mask = 0

	var shape: SphereShape3D = SphereShape3D.new()
	shape.radius = pick_radius
	var collision: CollisionShape3D = CollisionShape3D.new()
	collision.name = "NestPickerShape"
	collision.shape = shape
	collision.position = Vector3(0.0, pick_center_y, 0.0)
	body.add_child(collision)
	add_child(body)


## Human-readable shelter name for the given species (used in the inspector).
func _shelter_name() -> String:
	if in_tree:
		return "%s nest" % species
	match species:
		"bird":
			return "bird nest"
		"rabbit":
			return "rabbit burrow"
		"fox":
			return "fox den"
		"villager":
			return "villager hut"
		_:
			return "%s nest" % species


## A small woven twig cup for birds: a shallow brown bowl formed from a ring of
## short cylinders (the woven twigs) around a darker cone hollow. Sits at the
## caller-provided roost height (Y is left untouched).
func _build_twig_cup() -> void:
	_mesh_root = MeshInstance3D.new()
	_mesh_root.name = "NestMesh"
	add_child(_mesh_root)

	var twig_mat: StandardMaterial3D = StandardMaterial3D.new()
	twig_mat.albedo_color = Color(0.36, 0.24, 0.13)      # dry twig brown
	twig_mat.roughness = 1.0
	twig_mat.metallic = 0.0

	# A shallow bowl base so the cup reads as filled even at distance.
	var bowl_mat: StandardMaterial3D = StandardMaterial3D.new()
	bowl_mat.albedo_color = Color(0.24, 0.16, 0.09)      # darker hollow
	bowl_mat.roughness = 1.0
	bowl_mat.metallic = 0.0

	var bowl_mesh: SphereMesh = SphereMesh.new()
	bowl_mesh.radius = 0.24
	bowl_mesh.height = 0.48
	bowl_mesh.material = bowl_mat
	var bowl: MeshInstance3D = MeshInstance3D.new()
	bowl.name = "NestBowl"
	bowl.mesh = bowl_mesh
	bowl.position = Vector3(0.0, 0.02, 0.0)
	bowl.scale = Vector3(1.0, 0.35, 1.0)                 # squashed into a shallow dish
	_mesh_root.add_child(bowl)

	# A ring of short cylinders around the rim -- the woven twigs.
	var twig_count: int = 9
	var ring_radius: float = 0.24
	for i in range(twig_count):
		var frac: float = float(i) / float(twig_count)
		var angle: float = frac * TAU
		var twig_mesh: CylinderMesh = CylinderMesh.new()
		twig_mesh.top_radius = 0.03
		twig_mesh.bottom_radius = 0.04
		twig_mesh.height = 0.22
		twig_mesh.material = twig_mat

		var twig: MeshInstance3D = MeshInstance3D.new()
		twig.name = "NestTwig%d" % i
		twig.mesh = twig_mesh
		twig.position = Vector3(cos(angle) * ring_radius, 0.09, sin(angle) * ring_radius)
		# Tip each twig slightly outward and give it a little random lean so the
		# rim reads as roughly woven rather than a clean geometric ring.
		twig.rotation = Vector3(
			randf_range(-0.35, 0.35),
			angle,
			0.5 + randf_range(-0.2, 0.2)
		)
		_mesh_root.add_child(twig)


## A rabbit burrow: a small low earth mound with a clearly visible dark entrance
## hole dug into its front.
func _build_burrow() -> void:
	_build_mound(0.5, 0.36, Color(0.34, 0.25, 0.15), true, 0.16)


## A fox den: a larger, darker dug hollow in the earth with a wider entrance.
func _build_den() -> void:
	_build_mound(0.72, 0.42, Color(0.24, 0.17, 0.10), true, 0.24)


## A generic earthen mound for any unknown ground dweller: a flattened dome with
## a small dark entrance hollow.
func _build_earthen_mound() -> void:
	_build_mound(0.55, 0.40, Color(0.30, 0.22, 0.14), true, 0.18)


## Shared builder for the earthen-dome shelters (burrow / den / generic mound).
## `radius`/`flatten` size the flattened dome; `earth_color` tints it; when
## `with_entrance` is set a darker entrance hollow of `hole_radius` is dug into
## the front so the shelter reads as an occupied burrow.
func _build_mound(radius: float, flatten: float, earth_color: Color, with_entrance: bool, hole_radius: float) -> void:
	_mesh_root = MeshInstance3D.new()
	_mesh_root.name = "NestMesh"
	add_child(_mesh_root)

	var earth_mat: StandardMaterial3D = StandardMaterial3D.new()
	earth_mat.albedo_color = earth_color
	earth_mat.roughness = 1.0
	earth_mat.metallic = 0.0

	var dome_mesh: SphereMesh = SphereMesh.new()
	dome_mesh.radius = radius
	dome_mesh.height = radius * 2.0
	dome_mesh.material = earth_mat
	var dome: MeshInstance3D = MeshInstance3D.new()
	dome.name = "NestDome"
	dome.mesh = dome_mesh
	dome.position = Vector3(0.0, 0.0, 0.0)
	# Flatten it into a low mound sitting on the ground.
	dome.scale = Vector3(1.0, flatten, 1.0)
	_mesh_root.add_child(dome)

	if not with_entrance:
		return

	# A darker entrance hollow dug into the front of the mound.
	var hole_mat: StandardMaterial3D = StandardMaterial3D.new()
	hole_mat.albedo_color = Color(0.08, 0.06, 0.04)      # dark opening
	hole_mat.roughness = 1.0
	hole_mat.metallic = 0.0
	var hole_mesh: SphereMesh = SphereMesh.new()
	hole_mesh.radius = hole_radius
	hole_mesh.height = hole_radius * 2.0
	hole_mesh.material = hole_mat
	var hole: MeshInstance3D = MeshInstance3D.new()
	hole.name = "NestEntrance"
	hole.position = Vector3(0.0, hole_radius * 0.3, radius * 0.78)
	hole.mesh = hole_mesh
	_mesh_root.add_child(hole)


## A villager hut: a small square earth/wood floor with a simple cone "roof"
## raised above it, reading as a lean-to shelter on the ground.
func _build_hut() -> void:
	_mesh_root = MeshInstance3D.new()
	_mesh_root.name = "NestMesh"
	add_child(_mesh_root)

	# Low wooden floor / walls stub.
	var wall_mat: StandardMaterial3D = StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.45, 0.33, 0.20)      # light timber
	wall_mat.roughness = 1.0
	wall_mat.metallic = 0.0
	var wall_mesh: BoxMesh = BoxMesh.new()
	wall_mesh.size = Vector3(0.7, 0.35, 0.7)
	wall_mesh.material = wall_mat
	var walls: MeshInstance3D = MeshInstance3D.new()
	walls.name = "HutWalls"
	walls.mesh = wall_mesh
	walls.position = Vector3(0.0, 0.175, 0.0)
	_mesh_root.add_child(walls)

	# A conical thatch/earth roof raised above the walls.
	var roof_mat: StandardMaterial3D = StandardMaterial3D.new()
	roof_mat.albedo_color = Color(0.30, 0.21, 0.12)      # darker thatch
	roof_mat.roughness = 1.0
	roof_mat.metallic = 0.0
	var roof_mesh: CylinderMesh = CylinderMesh.new()     # cone: zero top radius
	roof_mesh.top_radius = 0.0
	roof_mesh.bottom_radius = 0.6
	roof_mesh.height = 0.5
	roof_mesh.material = roof_mat
	var roof: MeshInstance3D = MeshInstance3D.new()
	roof.name = "HutRoof"
	roof.mesh = roof_mesh
	roof.position = Vector3(0.0, 0.35 + 0.25, 0.0)
	_mesh_root.add_child(roof)


func _snap_to_terrain() -> void:
	if terrain == null:
		return
	# PLANET: snap onto the solid surface along our radial ray (the flat surface_height path is NAN here).
	if terrain.has_method("is_planet") and terrain.is_planet():
		var center: Vector3 = terrain.planet_center()
		var dir: Vector3 = (global_position - center).normalized()
		var surf: Vector3 = terrain.surface_point(dir)
		if not is_nan(surf.x):
			global_position = surf
		return
	if not terrain.has_method("surface_height"):
		return
	var height: float = terrain.surface_height(global_position.x, global_position.z)
	if is_nan(height):
		return
	global_position.y = height


## Align local +Y to the radial "up" so a ground shelter sits flat on a spherical planet. No-op on the
## flat island (default +Y orientation is preserved), keeping flat behaviour unchanged.
func _orient_radial() -> void:
	if terrain == null or not (terrain.has_method("is_planet") and terrain.is_planet()):
		return
	var up: Vector3 = terrain.up_at(global_position)
	if up.length() < 0.0001:
		return
	up = up.normalized()
	var ref: Vector3 = Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var right: Vector3 = up.cross(ref).normalized()
	var fwd: Vector3 = right.cross(up).normalized()
	global_transform.basis = Basis(right, up, fwd)


## Reset the idle timer -- called when an owner visits/tends the nest.
func touch() -> void:
	_idle = 0.0


## Record that a young creature has been raised at this nest.
func register_young() -> void:
	_young += 1


func young_count() -> int:
	return _young


## A human-readable condition string driven by how long the nest has been idle.
func condition() -> String:
	if _idle >= DISREPAIR_START:
		var t: float = clampf(
			(_idle - DISREPAIR_START) / maxf(IDLE_TIMEOUT - DISREPAIR_START, 0.001),
			0.0, 1.0
		)
		if t >= 0.66:
			return "crumbling"
		return "worn"
	return "well-kept"


func get_inspector_payload() -> Dictionary:
	return {
		"title": "Nest",
		"lines": [
			_shelter_name(),
			"Species: %s" % species,
			"Habitat: %s" % ("tree" if in_tree else "ground"),
			"Family: %d" % owner_family,
			"Young: %d" % young_count(),
			"Condition: %s" % condition(),
		],
	}


func _physics_process(delta: float) -> void:
	if _dead:
		return

	_age += delta
	_idle += delta

	if _idle >= IDLE_TIMEOUT:
		_free_once()


func _free_once() -> void:
	if _dead:
		return
	_dead = true
	queue_free()
