class_name LAPlanetBody
extends Node3D


const TerrainServiceScript: GDScript = preload("res://addons/local_agents/sim/terrain/VoxelTerrainService.gd")

var _terrain: RefCounted = null            # LAVoxelTerrainService (owns the VoxelLodTerrain child)
var actors_root: Node3D = null
## The row of LABodySeeds this body was built from, and the field whose matter IS this body. Mass, spin
## and radius are read off that field; nothing here is typed.
var _seed_key: String = "planet"
var _field = null


func setup(opts: Dictionary = {}) -> void:
	_seed_key = String(opts.get("seed_key", "planet"))

	_terrain = TerrainServiceScript.new()
	var t_opts: Dictionary = opts.duplicate()
	t_opts["center"] = Vector3.ZERO
	_terrain.build_planet(self, t_opts)

	actors_root = Node3D.new()
	actors_root.name = "Actors"
	add_child(actors_root)

	add_to_group(LAGravity.GROUP)


func terrain() -> RefCounted:
	return _terrain

## The field whose seeded matter this body IS. Its measurement is where mass and inertia come from.
func set_field(field) -> void:
	_field = field


func seed_row() -> Dictionary:
	return LANativeTables.body_seeds().of(_seed_key)


## THE MASS THE MATTER ADDS UP TO. Negative until the field has seeded, which a caller reads as unmeasured
## and refuses to size anything with; a body's mass is never a number somebody typed.
func mass() -> float:
	var m: Object = _measure()
	return -1.0 if m == null else m.mass_kg


func _measure() -> Object:
	if _field == null or not is_instance_valid(_field) or not _field.has_method("body_measure"):
		return null
	return _field.body_measure()


func is_gravity_reference() -> bool:
	return true

## The direction the seeded angular momentum points. Obliquity is an initial condition, not a property.
func spin_axis() -> Vector3:
	return LANativeTables.body_seeds().spin_axis_of(_seed_key)


## Spin rate, rad/s: seeded angular momentum over measured inertia, so a body that moves its mass about
## changes its own day. NAN until measured.
func angular_velocity_rad_s() -> float:
	var m: Object = _measure()
	if m == null:
		return NAN
	return m.angular_velocity_rad_s(LANativeTables.body_seeds().spin_l_of(_seed_key))


## Coriolis parameter is f = two_omega() * sin(latitude).
func two_omega_rad_s() -> float:
	return 2.0 * angular_velocity_rad_s()


func center() -> Vector3:
	return global_position

## Mean solid radius (world units).
func radius() -> float:
	return _terrain.planet_radius() if _terrain != null else 0.0

func sea_radius() -> float:
	return _terrain.sea_radius() if _terrain != null else 0.0

## Local "up" at a world point: radial from the body centre.
func up_at(world_pos: Vector3) -> Vector3:
	var r: Vector3 = world_pos - center()
	return r.normalized() if r.length() > 0.001 else Vector3.UP

## Height of a world point above the local ground (>0 in air, <0 underground). NAN if that patch is unmeshed.
func altitude_at(world_pos: Vector3) -> float:
	return _terrain.altitude_at(world_pos) if _terrain != null else NAN

## World-space surface point along a direction from the centre (for spawning ON the ground). NAN-vec if unmeshed.
func surface_point(dir: Vector3) -> Vector3:
	return _terrain.surface_point(dir) if _terrain != null else Vector3(NAN, NAN, NAN)

## World radius of the solid surface along `dir`. NAN if unmeshed.
func surface_radius(dir: Vector3) -> float:
	return _terrain.surface_radius(dir) if _terrain != null else NAN

## True where solid rock fills a world point (delegates to the terrain SDF).
func is_solid(world_pos: Vector3) -> bool:
	return _terrain != null and _terrain.is_solid(world_pos)

func sdf_at(world_pos: Vector3) -> float:
	return _terrain.sdf_at(world_pos) if _terrain != null else 999.0

## Destruction: remove SDF matter inside the sphere (impacts, eruptions, digging).
func carve_sphere(world_pos: Vector3, r: float) -> void:
	if _terrain != null:
		_terrain.carve_sphere(world_pos, r)

## True if terrain is meshed + collidable near world_pos (gates spawning).
func is_ready_at(world_pos: Vector3) -> bool:
	return _terrain != null and _terrain.is_ready_at(world_pos)

## Attach a VoxelViewer under `node` so terrain streams/meshes around it.
func attach_viewer(node: Node3D, visuals: bool = true) -> void:
	if _terrain != null:
		_terrain.attach_viewer(node, visuals)
