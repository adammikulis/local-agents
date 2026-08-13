class_name LAMaterialFieldGravity3D
extends RefCounted

## The CPU's read-only view of gravity. The solve itself is `kernels3d/gravity_poisson.glsl`, dispatched by
## GravityPass inside the field's own chain, straight into the buffer every kernel reads to know which way
## is down. Nothing here solves, and nothing here uploads.

const PASS_FILE: String = "GravityPass.gd"

var _f = null
var _pass = null


func setup(field) -> void:
	_f = field


## Binds to the device pass once the driver exists. No CPU step re-solves, so this never reports one.
func step() -> bool:
	_bind()
	return false


func _bind() -> void:
	if _pass != null or _f == null or _f._gpu == null:
		return
	for p in _f._gpu._passes:
		var scr: Script = p.get_script() as Script
		if scr != null and scr.resource_path.get_file() == PASS_FILE:
			_pass = p
			return


## Solves the device has completed; the geotherm rebuilds its source table on this cadence.
func solves() -> int:
	_bind()
	return int(_pass.solves()) if _pass != null else 0


## Mean |g| over the cells where gravity does not vanish, m/s^2. Reduced on the device.
func mean_g() -> float:
	_bind()
	return float(_pass.mean_g()) if _pass != null else 0.0


## The unit vector gravity points along at a cell — what "down" means here. Zero where g vanishes, and
## zero before the first solve has been drained.
func down_at(c: int) -> Vector3:
	_bind()
	if _pass == null or c < 0:
		return Vector3.ZERO
	var g: PackedFloat32Array = _pass.mirror()
	var base: int = c * 3
	if base + 2 >= g.size():
		return Vector3.ZERO
	var v: Vector3 = Vector3(g[base], g[base + 1], g[base + 2])
	var l: float = v.length()
	return (v / l) if l > 0.0 else Vector3.ZERO
