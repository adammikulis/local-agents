class_name LAFlatGroundTerrain
extends RefCounted

## Duck-typed TERRAIN adapter for a FLAT world — the standalone-creature counterpart of LAVoxelTerrainService
## (which is the SPHERE adapter). A Creature talks to its terrain ONLY through this duck-typed surface, so a
## creature can stand on a plain floor with no voxel planet at all: Creature.setup() defaults `terrain` to this
## when none is injected. Mirrors the LACognizerAdapter pattern — a new terrain kind = provide these methods,
## not patch the actor.
##
## THE DUCK-TYPED TERRAIN CONTRACT (the exact method surface every actor calls on `terrain`; both this flat
## adapter and LAVoxelTerrainService implement it identically in shape, differing only in geometry):
##   up_at(pos)            -> Vector3 : local "up" at a world point
##   planet_center()       -> Vector3 : the centre all radial math is measured from
##   sea_radius()          -> float   : world radius of the sea shell (<=0 / -INF ⇒ no sea)
##   surface_point(dir)    -> Vector3 : world point where the ray centre→dir meets the ground (NAN-vec if none)
##   surface_radius(dir)   -> float   : distance centre→that surface point (NAN if none)
##   ground_point(pos)     -> Vector3 : the ground point directly below a world point
##   altitude_at(pos)      -> float   : height of a world point ABOVE the local ground (>0 air, <0 underground)
##   is_planet()           -> bool    : radial-up planet (false here — flat +Y up)
##   is_ready_at(pos)      -> bool     : whether the ground under pos is queryable (always true here)
##   raycast_terrain(from,dir,max) -> Dictionary {hit,position,normal} : ray vs ground
##   carve_sphere(pos,r)   -> void    : destructive edit (no-op on flat ground)
##
## FLAT GEOMETRY. The ground is the plane y == ground_y (+Y up). To reuse the SPHERE actor movement path
## UNCHANGED — which does `dir = (pos - planet_center()).normalized()` then `surface_point(dir)` and finally
## `global_position = surface_point(dir) + dir * offset` — the "planet centre" sits FAR_BELOW the plane, so a
## radial from it through any near-ground point is ≈ +Y (up_at is exactly Vector3.UP) yet surface_point solves
## the exact RAY↔PLANE crossing, which preserves the point's horizontal x/z with full fp32 precision (a giant
## literal sphere would lose it). No sea, so land walkers never hit coast avoidance.
## (Explicit types only — project rule: no ':=' inferred typing.)

# World Y of the flat ground plane (the "sea datum" analogue). Configurable so a scene can raise/lower the floor.
var ground_y: float = 0.0
# How far below the plane the synthetic "planet centre" sits. Large enough that the radial up is ≈ +Y across a
# whole play area, small enough that (pos - centre) keeps the horizontal fp32-precise. 100 km of world units.
var far_below: float = 100000.0


func _init(p_ground_y: float = 0.0, p_far_below: float = 100000.0) -> void:
	ground_y = p_ground_y
	far_below = maxf(p_far_below, 1.0)


## Local up on a flat world is straight +Y everywhere (the synthetic centre is far enough below that the true
## radial is +Y to within ~1e-5; return the exact axis so tangent-plane math stays clean).
func up_at(_pos: Vector3) -> Vector3:
	return Vector3.UP


## FLAT: a real planet is a radial world; here we place the "centre" FAR_BELOW the ground plane so the actor's
## radial-up math degenerates to +Y while surface_point still recovers exact horizontal (see class doc).
func planet_center() -> Vector3:
	return Vector3(0.0, ground_y - far_below, 0.0)


## Distance from the synthetic centre to the ground plane (used by any radius-based query). Flat = far_below.
func planet_radius() -> float:
	return far_below


## No sea on a bare flat world. -INF so the walker coast-avoidance (`sea_r > 0.0`) is always skipped.
func sea_radius() -> float:
	return -INF


## Not a radial planet — flat +Y-up world.
func is_planet() -> bool:
	return false


## Distance from the synthetic centre, along `dir`, to where that ray crosses the ground plane y == ground_y.
## The centre is at y = ground_y - far_below, so the crossing is at parameter t = far_below / dir.y. NAN when
## `dir` does not point up toward the plane (degenerate — the caller then holds its last known ground).
func surface_radius(dir: Vector3) -> float:
	var d: Vector3 = dir.normalized()
	if d.y <= 1.0e-4:
		return NAN
	return far_below / d.y


## World point where the ray centre→`dir` meets the ground plane (centre + dir * surface_radius). This is the
## exact ray↔plane intersection, so for `dir = (pos - centre).normalized()` it returns `pos` snapped to the
## plane with its x/z intact — the flat twin of the sphere's centre + dir*r. NAN-vector if the ray misses.
func surface_point(dir: Vector3) -> Vector3:
	var r: float = surface_radius(dir)
	if is_nan(r):
		return Vector3(NAN, NAN, NAN)
	return planet_center() + dir.normalized() * r


## The ground point directly below `pos`: same x/z, snapped to the ground plane. Exact (no radial math needed).
func ground_point(pos: Vector3) -> Vector3:
	return Vector3(pos.x, ground_y, pos.z)


## Height of `pos` above the flat ground (>0 in the air, <0 below the floor).
func altitude_at(pos: Vector3) -> float:
	return pos.y - ground_y


## Flat ground is always queryable (nothing to mesh/stream in).
func is_ready_at(_pos: Vector3) -> bool:
	return true


## Ray vs the ground plane y == ground_y. Returns {hit, position, normal} matching the sphere service's shape,
## so a standalone actor (a thrown rock, a dropped body) that raycasts terrain still works. Misses when the ray
## is parallel to / points away from the plane, or the crossing is beyond `max_distance`.
func raycast_terrain(from: Vector3, dir: Vector3, max_distance: float) -> Dictionary:
	var miss: Dictionary = {"hit": false, "position": Vector3.ZERO, "normal": Vector3.UP}
	var d: Vector3 = dir.normalized()
	if absf(d.y) < 1.0e-6:
		return miss                                  # parallel to the plane
	var t: float = (ground_y - from.y) / d.y
	if t < 0.0 or t > max_distance:
		return miss                                  # behind the origin or past the ray
	return {"hit": true, "position": from + d * t, "normal": Vector3.UP}


## Destructive terrain edit — a bare flat ground has no voxel volume to carve, so this is a no-op (an actor
## that tries to blast a crater on the flat world simply leaves no crater; it does not crash).
func carve_sphere(_world_pos: Vector3, _radius: float) -> void:
	pass
