class_name LAMaterialFieldBoxStep3D
extends RefCounted

## LAMaterialFieldSphereStep3D: the field node stays a thin substrate/facade and merely delegates its

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
