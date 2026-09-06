class_name LAFlatGroundTerrain
extends RefCounted


var ground_y: float = 0.0
var far_below: float = 100000.0


func _init(p_ground_y: float = 0.0, p_far_below: float = 100000.0) -> void:
	ground_y = p_ground_y
	far_below = maxf(p_far_below, 1.0)


func up_at(_pos: Vector3) -> Vector3:
	return Vector3.UP


func planet_center() -> Vector3:
	return Vector3(0.0, ground_y - far_below, 0.0)


func planet_radius() -> float:
	return far_below


## No standing water on a bare flat world: NAN is what every reader takes for a dry column.
func water_surface_radius(_dir: Vector3) -> float:
	return NAN


## Not a radial planet — flat +Y-up world.
func is_planet() -> bool:
	return false


func surface_radius(dir: Vector3) -> float:
	var d: Vector3 = dir.normalized()
	if d.y <= 1.0e-4:
		return NAN
	return far_below / d.y


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


func raycast_terrain(from: Vector3, dir: Vector3, max_distance: float) -> Dictionary:
	var miss: Dictionary = {"hit": false, "position": Vector3.ZERO, "normal": Vector3.UP}
	var d: Vector3 = dir.normalized()
	if absf(d.y) < 1.0e-6:
		return miss                                  # parallel to the plane
	var t: float = (ground_y - from.y) / d.y
	if t < 0.0 or t > max_distance:
		return miss                                  # behind the origin or past the ray
	return {"hit": true, "position": from + d * t, "normal": Vector3.UP}

