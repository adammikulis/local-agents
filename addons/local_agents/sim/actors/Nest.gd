class_name LANest
extends Node3D


const IDLE_TIMEOUT: float = 120.0        # seconds of neglect before the nest rots away
const DISREPAIR_START: float = 60.0      # idle seconds after which condition visibly degrades

const HUT_SPEC: Dictionary = {
	"wall_radius": 1.35,                          # walls ~2.7 m across
	"wall_height": 1.7,                           # taller than a standing villager's shoulders
	"roof_radius": 1.62,                          # cone overhangs the walls (~3.2 m eaves)
	"roof_height": 1.15,                          # peak at 1.7 + 1.15 = 2.85 m
	"wall_color": Color(0.56, 0.42, 0.28),        # sun-dried mud / clay
	"roof_color": Color(0.34, 0.25, 0.14),        # dry thatch
}

var terrain: Object = null               # LAVoxelTerrainService (injected), may be null
var species: String = "creature"
var owner_family: int = -1
var in_tree: bool = false

var _young: int = 0
var _idle: float = 0.0                    # seconds since the last touch()
var _dead: bool = false

@onready var _mesh_root: MeshInstance3D = $NestMesh

# Materials and primitive meshes are the same for every shelter of a kind; one of each serves them all.
static var _shared: Dictionary = {}


static func _matte(color: Color, roughness: float) -> StandardMaterial3D:
	var key: String = "mat%s/%s" % [color, roughness]
	if not _shared.has(key):
		var m: StandardMaterial3D = StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = roughness
		m.metallic = 0.0
		_shared[key] = m
	return _shared[key]


static func _sphere(radius: float, mat: Material) -> SphereMesh:
	var key: String = "sphere%s/%d" % [radius, mat.get_instance_id()]
	if not _shared.has(key):
		var m: SphereMesh = SphereMesh.new()
		m.radius = radius
		m.height = radius * 2.0
		m.material = mat
		_shared[key] = m
	return _shared[key]


static func _cylinder(top: float, bottom: float, height: float, segments: int, mat: Material) -> CylinderMesh:
	var key: String = "cyl%s/%s/%s/%d/%d" % [top, bottom, height, segments, mat.get_instance_id()]
	if not _shared.has(key):
		var m: CylinderMesh = CylinderMesh.new()
		m.top_radius = top
		m.bottom_radius = bottom
		m.height = height
		if segments > 0:
			m.radial_segments = segments
		m.material = mat
		_shared[key] = m
	return _shared[key]
@onready var _picker_shape: CollisionShape3D = $NestPicker/NestPickerShape


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

	# Sized after the mesh is built so it matches the shelter that was chosen.
	_size_picker()


## Size and centre the pick-only sphere (layer 2, mask 0) so it roughly covers
## the built shelter's visual extents.
func _size_picker() -> void:
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
				pick_radius = 1.7          # covers the full-size hut (walls + lower roof)
				pick_center_y = 1.3
			_:
				pick_radius = 0.60
				pick_center_y = 0.12

	(_picker_shape.shape as SphereShape3D).radius = pick_radius
	_picker_shape.position = Vector3(0.0, pick_center_y, 0.0)


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
	var twig_mat: StandardMaterial3D = _matte(Color(0.36, 0.24, 0.13), 1.0)      # dry twig brown
	# A shallow bowl base so the cup reads as filled even at distance.
	var bowl_mat: StandardMaterial3D = _matte(Color(0.24, 0.16, 0.09), 1.0)      # darker hollow
	var bowl_mesh: SphereMesh = _sphere(0.24, bowl_mat)
	var bowl: MeshInstance3D = MeshInstance3D.new()
	bowl.name = "NestBowl"
	bowl.mesh = bowl_mesh
	bowl.position = Vector3(0.0, 0.02, 0.0)
	bowl.scale = Vector3(1.0, 0.35, 1.0)                 # squashed into a shallow dish
	_mesh_root.add_child(bowl)

	# A ring of short cylinders around the rim -- the woven twigs.
	var twig_count: int = 9
	var ring_radius: float = 0.24
	var rng: LASimRng = LASimRng.for_domain("actors")
	for i in range(twig_count):
		var frac: float = float(i) / float(twig_count)
		var angle: float = frac * TAU
		var twig_mesh: CylinderMesh = _cylinder(0.03, 0.04, 0.22, 0, twig_mat)

		var twig: MeshInstance3D = MeshInstance3D.new()
		twig.name = "NestTwig%d" % i
		twig.mesh = twig_mesh
		twig.position = Vector3(cos(angle) * ring_radius, 0.09, sin(angle) * ring_radius)
		# Tip each twig slightly outward and give it a little random lean so the
		# rim reads as roughly woven rather than a clean geometric ring.
		twig.rotation = Vector3(
			rng.randf_range(-0.35, 0.35),
			angle,
			0.5 + rng.randf_range(-0.2, 0.2)
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


func _build_mound(radius: float, flatten: float, earth_color: Color, with_entrance: bool, hole_radius: float) -> void:
	var earth_mat: StandardMaterial3D = _matte(earth_color, 1.0)
	var dome_mesh: SphereMesh = _sphere(radius, earth_mat)
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
	var hole_mat: StandardMaterial3D = _matte(Color(0.08, 0.06, 0.04), 1.0)      # dark opening
	var hole_mesh: SphereMesh = _sphere(hole_radius, hole_mat)
	var hole: MeshInstance3D = MeshInstance3D.new()
	hole.name = "NestEntrance"
	hole.position = Vector3(0.0, hole_radius * 0.3, radius * 0.78)
	hole.mesh = hole_mesh
	_mesh_root.add_child(hole)


func _build_hut() -> void:
	var wall_radius: float = HUT_SPEC["wall_radius"]
	var wall_height: float = HUT_SPEC["wall_height"]
	var roof_radius: float = HUT_SPEC["roof_radius"]
	var roof_height: float = HUT_SPEC["roof_height"]

	# Sun-dried mud/clay walls: matte (high roughness), no metal.
	var wall_mat: StandardMaterial3D = _matte(HUT_SPEC["wall_color"], 0.92)
	var wall_mesh: CylinderMesh = _cylinder(wall_radius, wall_radius, wall_height, 20, wall_mat)
	var walls: MeshInstance3D = MeshInstance3D.new()
	walls.name = "HutWalls"
	walls.mesh = wall_mesh
	walls.position = Vector3(0.0, wall_height * 0.5, 0.0)
	_mesh_root.add_child(walls)

	# Conical thatch roof overhanging the walls, its base resting on the wall top.
	var roof_mat: StandardMaterial3D = _matte(HUT_SPEC["roof_color"], 0.88)
	var roof_mesh: CylinderMesh = _cylinder(0.0, roof_radius, roof_height, 20, roof_mat)     # cone: zero top radius
	var roof: MeshInstance3D = MeshInstance3D.new()
	roof.name = "HutRoof"
	roof.mesh = roof_mesh
	roof.position = Vector3(0.0, wall_height + roof_height * 0.5, 0.0)
	_mesh_root.add_child(roof)

	# A dark doorway hollow set into the front wall so the hut reads as enterable.
	var door_mat: StandardMaterial3D = _matte(Color(0.06, 0.05, 0.03), 1.0)      # shadowed opening
	var door_h: float = wall_height * 0.72
	var door_mesh: BoxMesh = BoxMesh.new()
	door_mesh.size = Vector3(wall_radius * 0.72, door_h, 0.3)
	door_mesh.material = door_mat
	var door: MeshInstance3D = MeshInstance3D.new()
	door.name = "HutDoor"
	door.mesh = door_mesh
	door.position = Vector3(0.0, door_h * 0.5, wall_radius - 0.06)
	_mesh_root.add_child(door)


func _snap_to_terrain() -> void:
	if terrain == null:
		return
	# Snap onto the solid surface along our radial ray.
	var center: Vector3 = terrain.planet_center()
	var dir: Vector3 = (global_position - center).normalized()
	var surf: Vector3 = terrain.surface_point(dir)
	if not is_nan(surf.x):
		global_position = surf


## Align local +Y to the radial "up" so a ground shelter sits flat on a spherical planet.
func _orient_radial() -> void:
	if terrain == null:
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

	_idle += delta

	if _idle >= IDLE_TIMEOUT:
		_free_once()


func _free_once() -> void:
	if _dead:
		return
	_dead = true
	queue_free()
