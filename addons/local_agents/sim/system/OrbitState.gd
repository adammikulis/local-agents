class_name LAOrbitState
extends RefCounted

## A position and a velocity, in DOUBLES. Godot's Vector3 is binary32, whose spacing at one astronomical
## unit is thousands of metres — larger than the error budget of an orbit that has to close. The scene
## graph still takes a Vector3, because a light needs a direction rather than a metre.

var px: float = 0.0
var py: float = 0.0
var pz: float = 0.0
var vx: float = 0.0
var vy: float = 0.0
var vz: float = 0.0


func set_position(p: Vector3) -> void:
	px = p.x
	py = p.y
	pz = p.z


func set_velocity(v: Vector3) -> void:
	vx = v.x
	vy = v.y
	vz = v.z


func position() -> Vector3:
	return Vector3(px, py, pz)


func velocity() -> Vector3:
	return Vector3(vx, vy, vz)


func distance() -> float:
	return sqrt(px * px + py * py + pz * pz)


func speed() -> float:
	return sqrt(vx * vx + vy * vy + vz * vz)


## Advance under `accel` for `dt` seconds. Semi-implicit: velocity first, so a bound orbit stays bound
## instead of gaining energy every revolution the way explicit Euler does.
func advance(accel: Vector3, dt: float) -> void:
	vx += accel.x * dt
	vy += accel.y * dt
	vz += accel.z * dt
	px += vx * dt
	py += vy * dt
	pz += vz * dt
