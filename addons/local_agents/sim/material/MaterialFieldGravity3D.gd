class_name LAMaterialFieldGravity3D
extends RefCounted

## The CPU's read-only view of gravity. The solve itself is `kernels3d/gravity_poisson.glsl`, dispatched by
## GravityPass inside the field's own chain, straight into the buffer every kernel reads to know which way
## is down. Nothing here uploads, and the only solve it asks for is the seeding one below.

const PASS_FILE: String = "GravityPass.gd"


var _f = null
var _pass = null
var _switched_off: bool = false     # the last step ran with gravity switched off


func setup(field) -> void:
	_f = field


## Every SOLVE_EVERY steps the potential is re-solved from the mass that moved, warm-started. With the
## switch off nothing is solved, and the pass zeroes what it published; the first step back re-solves.
func solve_step(step_index: int) -> void:
	_bind()
	var on: bool = _pass != null and LAProcessSet.is_active("pass", PASS_FILE)
	# The bodies moved, so the tide they raise moved: refilled before the derive reads it.
	LABallistics.upload_tide(_f._gpu._rd, _f._gpu._bufs.get("tide_bodies", RID()))
	if on and (_switched_off or step_index % _pass.SOLVE_EVERY == 0):
		solve()
	_switched_off = not on


## GravityPass alone, CONVERGED. Its own ctx: no dt is consumed, no step index moves.
func solve() -> void:
	if _f._slice != null:
		_solve_slice()
		return
	_bind()
	if _pass == null or _f._gpu == null or _f._gpu._rd == null:
		return
	_pass.set_datum(0.5 * float(_f._grid.nx) * _f._grid.cell_size)
	var rel: float = _pass.solve_converged(_f._gpu._rd, _f._grid, _f._gpu._cc, _f._gpu._groups)
	if rel > _pass.RESIDUAL_TOLERANCE:
		push_error(("The gravity solve did not converge: the discrete Poisson residual is still %f of its "
			+ "source. Every `above`/`below` walk below this — pressure, the regolith burial march, the "
			+ "lake flood, the surface seed — is reading a direction the solve has not yet produced.") % rel)


## The full potential per cell in double, J/kg: a slab's is the body's own field; a planet's is the
## device's deviation plus the reference the solve stated it against.
func phi_abs() -> PackedFloat64Array:
	if not _phi_slab.is_empty():
		return _phi_slab
	return LAGravitySolve.phi_abs(_f._grid, _f._gpu.read_raw("grav_phi"), _f._gpu.read_raw("grav_moments"),
		LAPhysical.GRAVITATIONAL_CONSTANT)


var _phi_slab: PackedFloat64Array = PackedFloat64Array()
var _phi_datum_slab: float = 0.0


## The potential at the datum against infinity, J/kg: the device's la_phi plus this is the full potential.
func phi_datum() -> float:
	if not _phi_slab.is_empty():
		return _phi_datum_slab
	_bind()
	return float(_pass.phi_datum()) if _pass != null else 0.0


## SLICE: a partial slab cannot solve Poisson — its own mass is not the field's source. The DECLARED
## body's own field, g = G m(<r)/r^2 from the radial profile it was seeded from, is uploaded once.
## LA_APPROX: slice_monopole_gravity
func _solve_slice() -> void:
	_bind()
	if _pass == null or _f._gpu == null or _f._gpu._rd == null:
		return
	var body = _f._body
	if body == null or not body.has_method("radius") or not body.has_method("center"):
		push_error("SLICE_NO_BODY: slice mode has no declared body, so gravity has no mass to point at. "
			+ "Declare the body (set_body) before the seed.")
		return
	var bf: Dictionary = LAPlanetComposition.upload_body_field(_f._gpu._rd, _f._gpu._bufs, _f._grid,
		_f.centre(), float(body.radius()), LABodySeeds.surface_temp_c())
	if bf.is_empty():
		return
	_phi_slab = bf["phi"]
	_phi_datum_slab = float(bf["phi_datum"])
	var rd: RenderingDevice = _f._gpu._rd
	var cl: int = rd.compute_list_begin()
	_pass.dispatch_slab(rd, cl, _f._gpu._cc, _f._gpu._groups)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	_pass._drain(rd)


func _bind() -> void:
	if _pass != null or _f == null or _f._gpu == null:
		return
	for p in _f._gpu._passes:
		var scr: Script = p.get_script() as Script
		if scr != null and scr.resource_path.get_file() == PASS_FILE:
			_pass = p
			return



## The drained gravity mirror, flat cell*3, m/s^2. Empty before the first drain, and zero once the pass
## has been switched off — this is what LABallistics and every CPU vertical walk read.
func mirror() -> PackedFloat32Array:
	_bind()
	return _pass.mirror() if _pass != null else PackedFloat32Array()


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


## The solved (or, in slice mode, declared-monopole) acceleration at a cell, m/s^2.
func g_vec_at(c: int) -> Vector3:
	_bind()
	if _pass == null or c < 0:
		return Vector3.ZERO
	var g: PackedFloat32Array = _pass.mirror()
	var base: int = c * 3
	if base + 2 >= g.size():
		return Vector3.ZERO
	return Vector3(g[base], g[base + 1], g[base + 2])
