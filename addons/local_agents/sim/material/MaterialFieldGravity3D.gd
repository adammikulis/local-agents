class_name LAMaterialFieldGravity3D
extends RefCounted

## The Poisson gravity solve and the bulk density that sources it.

const GravityScript: GDScript = preload("res://addons/local_agents/sim/voxel/FieldGravity.gd")
const DensityScript: GDScript = preload("res://addons/local_agents/sim/material/FieldDensity3D.gd")

const SOLVE_EVERY: int = 8
const SWEEPS: int = 8

var _f = null
var _solver: LAFieldGravity = null
var _steps: int = 0
var _solves: int = 0
var _density: PackedFloat32Array = PackedFloat32Array()


func setup(field) -> void:
	_f = field
	if field._grid == null:
		return
	_solver = GravityScript.new()
	_solver.setup(field._grid)


## Channel name -> its per-cell mirror, plus the derived buffers the equation of state needs.
func _mirrors() -> Dictionary:
	var out: Dictionary = {}
	var rows: Dictionary = LAChannels.rows()
	for name in rows:
		var arr = _f.get("_" + String(name))
		if arr is PackedFloat32Array:
			out[String(name)] = arr
	for name in LAChannels.derived_buffers():
		var d = _f.get("_" + String(name))
		if d is PackedFloat32Array:
			out[String(name)] = d
	return out


## Re-solve if this step is due. Returns true when a solve actually ran.
func step() -> bool:
	if _solver == null:
		return false
	_steps += 1
	if _steps % SOLVE_EVERY != 1 and _steps != 1:
		return false
	_density = DensityScript.of(_mirrors(), _f._cell_count)
	_solver.solve(_density, SWEEPS)
	_solves += 1
	return true


## Bulk density per cell, kg/m^3, as of the last solve. Empty until one has run.
func density() -> PackedFloat32Array:
	return _density


## Solves completed.
func solves() -> int:
	return _solves


## Gravitational acceleration at a cell, m/s^2; zero before the first solve.
func g_at(c: int) -> Vector3:
	if _solver == null or c < 0 or c >= _solver.gx.size():
		return Vector3.ZERO
	return _solver.g_at(c)


## The unit vector gravity points along at a cell — what "down" means here. Zero where g vanishes.
func down_at(c: int) -> Vector3:
	if _solver == null or c < 0 or c >= _solver.gx.size():
		return Vector3.ZERO
	return _solver.down_at(c)


## Mean |g| over cells where gravity is non-zero, m/s^2.
func mean_g() -> float:
	if _solver == null:
		return 0.0
	var n: int = _solver.gx.size()
	var acc: float = 0.0
	var hits: int = 0
	for c in n:
		var m: float = _solver.g_at(c).length()
		if m > 0.0:
			acc += m
			hits += 1
	return acc / float(hits) if hits > 0 else 0.0


## The three acceleration components, flat cell*3, for upload to the kernels.
func packed() -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	if _solver == null:
		return out
	var n: int = _solver.gx.size()
	out.resize(n * 3)
	for c in n:
		out[c * 3] = _solver.gx[c]
		out[c * 3 + 1] = _solver.gy[c]
		out[c * 3 + 2] = _solver.gz[c]
	return out


func report() -> Dictionary:
	if _solver == null:
		return {}
	return {
		"gravity_residual": _solver.last_residual,
		"gravity_sweeps": _solver.last_sweeps,
		"gravity_total_mass_kg": _solver.total_mass,
		"gravity_com": _solver.centre_of_mass,
	}
