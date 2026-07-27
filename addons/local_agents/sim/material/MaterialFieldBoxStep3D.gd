class_name LAMaterialFieldBoxStep3D
extends RefCounted

## LAMaterialFieldBoxStep3D — the per-frame STEP ORCHESTRATION for LAMaterialField3D's BOX mode (setup_dims):
## an origin-box volume with no cubed-sphere grid and no planet terrain. It is the box twin of
## LAMaterialFieldSphereStep3D: the field node stays a thin substrate/facade and merely delegates its
## _physics_process to this module when the field is a box.
##
## Box mode has no *_sphere3d GPU kernels (those are all cubed-sphere), and it must also run HEADLESS (no
## RenderingDevice), so this is a small CPU heat stepper — a fixed-step 3D thermal relaxation with an upward
## BUOYANCY bias so injected heat both diffuses AND rises, making the field visibly non-static (a hot blob
## climbs + spreads). It is the CPU reference/oracle form the repo sanctions for a per-cell field that has no
## GPU kernel yet. It holds NO state of its own: it reaches into the owning field (`_f`) for the `_temp`
## array, the dimensions and the step accumulator, exactly as the sphere-step + query/inject modules do.
##
## Only TEMPERATURE is stepped here — box mode is a volumetric heat sandbox (the library demo that exercises
## setup_dims). Water/gas/scent/etc. are cubed-sphere channels; they stay inert (safe defaults) in box mode.
## (Explicit types only — project rule: no ':=' inferred typing.)

const STEP_DT: float = 1.0 / 20.0                  # fixed thermal step (20 Hz)
const MAX_STEPS_PER_FRAME: int = 3
# Explicit-diffusion coefficient per axis-pair. 6-neighbour Laplacian; kept < 1/6 for stability so the
# scheme never overshoots (with all 6 neighbours the safe bound is DIFF*6 < 1 → DIFF < 0.1667).
const DIFF: float = 0.14
# Buoyancy: a hot cell also pushes a fraction of its heat straight UP each step, so warmth rises (a plume)
# instead of only blurring outward — the "watch it flow" behaviour. Scaled by the cell's excess over ambient.
const BUOY: float = 0.10

var _f = null                                       # back-reference to the owning LAMaterialField3D
var _tnext: PackedFloat32Array = PackedFloat32Array()


func setup(field) -> void:
	_f = field


## Box per-frame step: bank dt, then run up to MAX_STEPS fixed thermal steps. Called from the field's
## _physics_process when the field is NOT a sphere (box mode). No GPU, no terrain — pure CPU relaxation.
func process(delta: float) -> void:
	if _f == null or _f._temp.size() != _f._cell_count or _f._cell_count <= 0:
		return
	_f._step_accum += delta
	_f._step_accum = minf(_f._step_accum, STEP_DT * float(MAX_STEPS_PER_FRAME + 1))
	var steps: int = 0
	while _f._step_accum >= STEP_DT and steps < MAX_STEPS_PER_FRAME:
		_f._step_accum -= STEP_DT
		_step_once()
		steps += 1


## One explicit thermal step over the box grid, in two clean passes:
##   1. 6-neighbour diffusion of _temp (insulated walls) → _tnext.
##   2. upward BUOYANCY transfer over _tnext: each open cell hands a fraction of its excess-over-ambient to
##      the cell above, so warmth rises into a plume instead of only blurring.
## Void-only (box mode seeds no solids); an authored solid cell is treated as an insulated wall.
func _step_once() -> void:
	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var n: int = _f._cell_count
	if _tnext.size() != n:
		_tnext.resize(n)
	var temp: PackedFloat32Array = _f._temp
	var solid: PackedByteArray = _f._solid
	var ambient: float = _f.INITIAL_TEMP
	var layer: int = dx * dz
	# Pass 1 — diffusion.
	for iy in range(dy):
		for iz in range(dz):
			var row: int = (iy * dz + iz) * dx
			for ix in range(dx):
				var c: int = row + ix
				if solid.size() == n and solid[c] != 0:
					_tnext[c] = temp[c]
					continue
				var here: float = temp[c]
				var acc: float = 0.0
				acc += _nb(temp, solid, n, ix > 0, c - 1, here)
				acc += _nb(temp, solid, n, ix < dx - 1, c + 1, here)
				acc += _nb(temp, solid, n, iz > 0, c - dx, here)
				acc += _nb(temp, solid, n, iz < dz - 1, c + dx, here)
				acc += _nb(temp, solid, n, iy > 0, c - layer, here)
				acc += _nb(temp, solid, n, iy < dy - 1, c + layer, here)
				_tnext[c] = here + DIFF * (acc - 6.0 * here)
	# Pass 2 — buoyancy transfer upward (sweep bottom-up so each lift is seen before the donor is revisited).
	for iy in range(dy - 1):                          # top layer has nowhere to rise to
		for iz in range(dz):
			var brow: int = (iy * dz + iz) * dx
			for ix in range(dx):
				var bc: int = brow + ix
				if solid.size() == n and solid[bc] != 0:
					continue
				var above: int = bc + layer
				if solid.size() == n and solid[above] != 0:
					continue
				var lift: float = BUOY * maxf(0.0, _tnext[bc] - ambient)
				if lift > 0.0:
					_tnext[bc] = _tnext[bc] - lift
					_tnext[above] = _tnext[above] + lift
	var tmp: PackedFloat32Array = _f._temp
	_f._temp = _tnext
	_tnext = tmp
	_f._atmos_dirty = true


# One neighbour's contribution to the Laplacian accumulator: the neighbour temp if it exists + is open,
# else the cell's own temp (a zero-flux / insulated wall, so edges don't leak heat to a phantom cold cell).
func _nb(temp: PackedFloat32Array, solid: PackedByteArray, n: int, in_range: bool, nc: int, here: float) -> float:
	if not in_range:
		return here
	if solid.size() == n and solid[nc] != 0:
		return here
	return temp[nc]
