class_name LAPlanetBody
extends Node3D


const TerrainServiceScript: GDScript = preload("res://addons/local_agents/sim/terrain/VoxelTerrainService.gd")
const SPIN_AXIS: Vector3 = Vector3(0.40, 0.92, 0.0)   # world space, 23.5 deg obliquity

var _terrain: RefCounted = null            # LAVoxelTerrainService (owns the VoxelLodTerrain child)
var actors_root: Node3D = null
var _mass: float = 1.0e6
var _atmosphere_height: float = 60.0       # shell thickness above the surface (frame-handoff boundary)


func setup(opts: Dictionary = {}) -> void:
	_mass = float(opts.get("mass", 1.0e6))
	_atmosphere_height = float(opts.get("atmosphere_height", 60.0))

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

func mass() -> float:
	return _mass

func is_gravity_reference() -> bool:
	return true

func spin_axis() -> Vector3:
	return SPIN_AXIS.normalized()


func center() -> Vector3:
	return global_position

## Mean solid radius (world units).
func radius() -> float:
	return _terrain.planet_radius() if _terrain != null else 0.0

func sea_radius() -> float:
	return _terrain.sea_radius() if _terrain != null else 0.0

func atmosphere_radius() -> float:
	return radius() + _atmosphere_height

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
