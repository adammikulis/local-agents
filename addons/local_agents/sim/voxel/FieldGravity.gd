class_name LAFieldGravity
extends RefCounted

## GRAVITY SOLVED FROM THE MASS THAT IS THERE. Poisson's equation on the uniform grid:
##
##     laplacian(phi) = 4 pi G rho        g = -grad(phi)
##
## WHY A SOLVE AND NOT A CENTRE-OF-MASS SHORTCUT. `g = -GM r_hat / r^2` about a centre of mass is the
## field of a SPHERE. Using it would re-assert the spherical symmetry the cubed-sphere grid asserted and
## this grid exists to stop asserting — the planet would be round because the gravity model says so,
## which is the defect wearing different clothes. A Poisson solve assumes no shape: it is correct for a
## shattered body, an accreting one, a contact binary, two bodies in one box, or a ring.
##
## IT IS ALSO ONLY CHEAP BECAUSE THE GRID IS UNIFORM. The 7-point laplacian is a constant stencil, so
## the solve is a stencil sweep. On a curvilinear grid the operator varies per cell and this is a far
## worse problem. The grid change is what makes emergent gravity affordable.
##
## METHOD. Red-black Gauss-Seidel, warm-started from the previous step's potential. Mass moves slowly
## compared to a step, so a handful of sweeps per step tracks it; the residual is reported rather than
## assumed. Boundary: the isolated-body condition phi = -G M / |r - com| on the box faces, which is exact
## in the limit of a distant boundary and makes NO assumption about the interior — it is a statement
## about the vacuum outside, where the multipole expansion's monopole term dominates.
##
## (Explicit types only, no ':=' inferred typing.)

## Newton's constant, m^3 kg^-1 s^-2. Bound to the SSOT, not a second copy.
const G_SI: float = LAPhysical.GRAVITATIONAL_CONSTANT

## THE SOLVE IS ENTIRELY IN SI. G is in m^3 kg^-1 s^-2, so every length here is METRES and the grid's
## model units are converted once, at setup. Mixing the two silently gives a potential wrong by the cube
## of LAPhysical.METRES_PER_MODEL_UNIT.
var grid: LAVoxelGrid = null
var metres_per_unit: float = 1.0
var h_m: float = 0.0                                     # cell size in metres
var phi: PackedFloat32Array = PackedFloat32Array()      # potential, J/kg
var gx: PackedFloat32Array = PackedFloat32Array()        # acceleration, m/s^2
var gy: PackedFloat32Array = PackedFloat32Array()
var gz: PackedFloat32Array = PackedFloat32Array()

var last_residual: float = 0.0
var last_sweeps: int = 0
var total_mass: float = 0.0
var centre_of_mass: Vector3 = Vector3.ZERO


func setup(p_grid: LAVoxelGrid, p_metres_per_unit: float = LAPhysical.METRES_PER_MODEL_UNIT) -> void:
	grid = p_grid
	metres_per_unit = maxf(p_metres_per_unit, 1.0e-12)
	h_m = grid.cell_size * metres_per_unit
	phi.resize(grid.cell_count)
	gx.resize(grid.cell_count)
	gy.resize(grid.cell_count)
	gz.resize(grid.cell_count)
	phi.fill(0.0)


## Total mass and centre of mass of `density` (kg/m^3), used only for the boundary. Positions in metres.
func _measure(density: PackedFloat32Array) -> void:
	var vol: float = h_m * h_m * h_m
	var m: float = 0.0
	var acc: Vector3 = Vector3.ZERO
	for c in grid.cell_count:
		var dm: float = density[c] * vol
		if dm <= 0.0:
			continue
		m += dm
		acc += grid.cell_world_pos(c) * metres_per_unit * dm
	total_mass = m
	centre_of_mass = (acc / m) if m > 0.0 else Vector3.ZERO


## Dirichlet value on a boundary cell: the monopole potential of the enclosed mass.
func _boundary_phi(c: int) -> float:
	if total_mass <= 0.0:
		return 0.0
	var r: float = (grid.cell_world_pos(c) * metres_per_unit - centre_of_mass).length()
	return -G_SI * total_mass / maxf(r, h_m)


func _is_boundary(c: int) -> bool:
	var base: int = c * LAVoxelGrid.SLOTS
	for d in LAVoxelGrid.SLOTS:
		if grid.neighbours[base + d] < 0:
			return true
	return false


## Solve to `sweeps` red-black passes and update g. Returns the max residual.
func solve(density: PackedFloat32Array, sweeps: int = 8) -> float:
	if grid == null or density.size() != grid.cell_count:
		push_error("LAFieldGravity.solve: density does not match the grid.")
		return NAN
	_measure(density)
	var h2: float = h_m * h_m
	var src_k: float = 4.0 * PI * G_SI * h2
	for c in grid.cell_count:
		if _is_boundary(c):
			phi[c] = _boundary_phi(c)
	for _s in sweeps:
		for parity in 2:
			for c in grid.cell_count:
				var p: Vector3i = grid.coords(c)
				if ((p.x + p.y + p.z) & 1) != parity:
					continue
				if _is_boundary(c):
					continue
				var base: int = c * LAVoxelGrid.SLOTS
				var sum: float = 0.0
				for d in LAVoxelGrid.SLOTS:
					sum += phi[grid.neighbours[base + d]]
				phi[c] = (sum - src_k * density[c]) / 6.0
	last_sweeps = sweeps
	last_residual = _residual(density, h2, src_k)
	_gradient()
	return last_residual


## max |laplacian(phi) - 4 pi G rho| over interior cells, in the discrete operator's own units.
func _residual(density: PackedFloat32Array, h2: float, src_k: float) -> float:
	var worst: float = 0.0
	for c in grid.cell_count:
		if _is_boundary(c):
			continue
		var base: int = c * LAVoxelGrid.SLOTS
		var sum: float = 0.0
		for d in LAVoxelGrid.SLOTS:
			sum += phi[grid.neighbours[base + d]]
		worst = maxf(worst, absf(sum - 6.0 * phi[c] - src_k * density[c]) / h2)
	return worst


## g = -grad(phi), central differences where both neighbours exist, one-sided at the box face. m/s^2.
func _gradient() -> void:
	var h: float = h_m
	for c in grid.cell_count:
		var base: int = c * LAVoxelGrid.SLOTS
		gx[c] = -_deriv(base, LAVoxelGrid.S_NEG_X, LAVoxelGrid.S_POS_X, c, h)
		gy[c] = -_deriv(base, LAVoxelGrid.S_NEG_Y, LAVoxelGrid.S_POS_Y, c, h)
		gz[c] = -_deriv(base, LAVoxelGrid.S_NEG_Z, LAVoxelGrid.S_POS_Z, c, h)


func _deriv(base: int, lo_slot: int, hi_slot: int, c: int, h: float) -> float:
	var lo: int = grid.neighbours[base + lo_slot]
	var hi: int = grid.neighbours[base + hi_slot]
	if lo >= 0 and hi >= 0:
		return (phi[hi] - phi[lo]) / (2.0 * h)
	if hi >= 0:
		return (phi[hi] - phi[c]) / h
	if lo >= 0:
		return (phi[c] - phi[lo]) / h
	return 0.0


## Acceleration vector at cell `c`, m/s^2.
func g_at(c: int) -> Vector3:
	return Vector3(gx[c], gy[c], gz[c])


## DOWN at cell `c` — the unit vector gravity points along. This is what the old grid's slot 0 was, and
## the reason it must be read rather than indexed: on a uniform grid there is no privileged direction.
## Zero-length where the field vanishes (the centre of a body, or empty space far from any mass).
func down_at(c: int) -> Vector3:
	var v: Vector3 = g_at(c)
	var l: float = v.length()
	return (v / l) if l > 0.0 else Vector3.ZERO


## The slot most closely aligned with down at `c`, for kernels that still step cell-to-cell. -1 where
## gravity vanishes. A stopgap shape for the column walks: the honest form is a march along down_at.
func down_slot(c: int) -> int:
	var v: Vector3 = down_at(c)
	if v == Vector3.ZERO:
		return -1
	var best: int = -1
	var best_dot: float = 0.0
	for d in LAVoxelGrid.SLOTS:
		var s: Vector3 = Vector3(LAVoxelGrid.SLOT_STEP[d])
		var dot: float = v.dot(s)
		if dot > best_dot:
			best_dot = dot
			best = d
	return best
