class_name LAMaterialFieldGravity3D
extends RefCounted

## The CPU's read-only view of gravity. The solve itself is `kernels3d/gravity_poisson.glsl`, dispatched by
## GravityPass inside the field's own chain, straight into the buffer every kernel reads to know which way
## is down. Nothing here uploads, and the only solve it asks for is the seeding one below.

const PASS_FILE: String = "GravityPass.gd"

## Residual, as a fraction of its own source, the seeding solve relaxes to. docs/MODEL_PARAMETERS.md.
const SEED_RESIDUAL_TOLERANCE: float = 1.0e-3
const SEED_DISPATCH_CAP: int = 512

var _f = null
var _pass = null


func setup(field) -> void:
	_f = field


## SEEDING: GravityPass alone, RELAXED TO CONVERGENCE, so `down_at` answers before the first step. Poisson
## is elliptic, so a fixed sweep count is not a solve. Its own ctx: no dt is consumed, no step index moves.
func solve_seed() -> void:
	_bind()
	if _pass == null or _f._gpu == null or _f._gpu._rd == null:
		return
	var rd: RenderingDevice = _f._gpu._rd
	var ctx: Dictionary = {"step_index": 0, "cell_size": _f._grid.cell_size}
	var rel: float = INF
	var dispatches: int = 0
	while rel > SEED_RESIDUAL_TOLERANCE and dispatches < SEED_DISPATCH_CAP:
		var cl: int = rd.compute_list_begin()
		_pass.dispatch(rd, cl, ctx, _f._gpu._cc, _f._gpu._groups)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		_pass._drain(rd)
		rel = float(_pass.residual_rel())
		dispatches += 1
	if rel > SEED_RESIDUAL_TOLERANCE:
		push_error(("The gravity solve did not converge in %d dispatches: the discrete Poisson residual is "
			+ "still %f of its source. Every `above`/`below` walk below this — pressure, the regolith "
			+ "burial march, the lake flood, the surface seed — is reading a direction the solve has not "
			+ "yet produced.") % [dispatches, rel])


func _bind() -> void:
	if _pass != null or _f == null or _f._gpu == null:
		return
	for p in _f._gpu._passes:
		var scr: Script = p.get_script() as Script
		if scr != null and scr.resource_path.get_file() == PASS_FILE:
			_pass = p
			return



## The solved vertical relation: cell -> the neighbour above it, and its inverse. Empty before the drain.
func up_table() -> PackedInt32Array:
	_bind()
	return _pass.up_table() if _pass != null else PackedInt32Array()


func down_table() -> PackedInt32Array:
	_bind()
	return _pass.down_table() if _pass != null else PackedInt32Array()


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
