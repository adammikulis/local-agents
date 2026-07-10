class_name LAPlanetBody
extends Node3D

## ONE body in the SOLAR-SYSTEM-FIRST spine (see TODO "SOLAR-SYSTEM-FIRST"). A self-contained world in a
## LOCAL frame: this node's Transform3D IS the body's orbital position + axial spin, and its terrain / field /
## ocean / actors are children, so they ride that transform (stand on a spinning planet, its air+sea turn with
## you). Radial "up" is (world_pos - center).normalized(). Owns:
##   - terrain: LAVoxelTerrainService.build_planet (native SDF sphere)
##   - actors_root: everything alive on this body
##   - (folded in as the VoxelWorld migration proceeds) the body-local MaterialField, ocean shell, ecology
## Exposes the radial contract every actor/camera/spawn uses: center/radius/sea_radius/up_at/altitude_at/
## surface_point/is_solid/carve. `mass` is the gravity source for the system's n-body integrator (Phase later).
## (Explicit types only — no ':=' .)

const TerrainServiceScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/terrain/VoxelTerrainService.gd")

var _terrain: RefCounted = null            # LAVoxelTerrainService (owns the VoxelLodTerrain child)
var actors_root: Node3D = null
var _mass: float = 1.0e6
var _atmosphere_height: float = 60.0       # shell thickness above the surface (frame-handoff boundary)


## Build this body. opts: radius, sea_radius, relief, feature_size, octaves, seed, mass, atmosphere_height,
## lod_count, lod_distance, view_distance. The body sits at its own Transform3D (identity = world origin).
func setup(opts: Dictionary = {}) -> void:
	_mass = float(opts.get("mass", 1.0e6))
	_atmosphere_height = float(opts.get("atmosphere_height", 60.0))

	_terrain = TerrainServiceScript.new()
	# Terrain becomes a CHILD of this body so it rides the body transform. Its centre is the body origin.
	var t_opts: Dictionary = opts.duplicate()
	t_opts["center"] = Vector3.ZERO
	_terrain.build_planet(self, t_opts)

	actors_root = Node3D.new()
	actors_root.name = "Actors"
	add_child(actors_root)

	# Register as a gravity source for the N-body integrator (LAGravity). Every free body (meteors, ejecta,
	# ships) is a test particle summing the pull of all `gravity_body` members — orbits/flybys/slingshots emerge.
	add_to_group("gravity_body")


func terrain() -> RefCounted:
	return _terrain

func mass() -> float:
	return _mass

## World-space centre of the body (its node origin). Radial "up"/gravity reference for everything on it.
func center() -> Vector3:
	return global_position

## Mean solid radius (world units).
func radius() -> float:
	return _terrain.planet_radius() if _terrain != null else 0.0

## Radius of the spherical sea shell.
func sea_radius() -> float:
	return _terrain.sea_radius() if _terrain != null else 0.0

## Top of the atmosphere shell (surface + atmosphere_height) — the free/bound reference-frame boundary.
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
func attach_viewer(node: Node3D) -> void:
	if _terrain != null:
		_terrain.attach_viewer(node)
