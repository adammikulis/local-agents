class_name LAMaterialShock3D
extends RefCounted

## LAMaterialShock3D — the emergent SOUND / SHOCK pressure-wave process of the dense LAMaterialField3D.
## It REPLACES the old point-based seismic ring (EcologyService._seismic_pulses / broadcast_seismic /
## seismic_energy_at): instead of listeners summing distance-falloff from a list of point sources, shock
## is a real PROPAGATING SCALAR FIELD that radiates OUTWARD through the 3D volume and DECAYS — so panic,
## camera tremor, and startle all fall out of the SPATIAL shock value at a cell, not from per-event math.
##
## Mirrors the shape of LAMaterialCombustion3D / LAMaterialWind3D: it reaches into the owning field (`_f`)
## for geometry (`_dim_*`, `_cell_size`, `_origin`, `_cell_count`) and the rock mask (`_solid`), but OWNS
## its own channel — `_shock` (loudness/energy per cell) + a `_scratch` double buffer — in-module (like the
## seismic ring used to live in EcologyService), because no GPU kernel reads it yet. Keeping it here leaves
## the field file tiny.
##
## EMERGENT-EVERYTHING (see EMERGENCE.md): there is NO scripted blast radius, no per-event scare list. Shock
## falls out of three local rules over the ONE `_shock` channel:
##   INJECT   — every violent event (meteor impact, volcano breach, thunder, lightning, a big stampede)
##              calls emit(world_pos, magnitude), which ADDS magnitude to `_shock` at that cell. That is the
##              single stimulus; the source is never special-cased.
##   PROPAGATE— a fast diffusion-with-decay gather: each cell relaxes toward the average of its 6 neighbours
##              (high SPREAD so the wave radiates several cells/step) and loses a fixed fraction each step
##              (LOSS) so it dies within ~1-2 s. A SOLID neighbour REFLECTS (reads this cell's own value), so
##              shock cannot transmit through rock — a blast behind a ridge is MUFFLED emergently (the wave
##              has to travel around/over the terrain). This is the stable fast-diffusion approximation of a
##              wave; a true wave equation would need a velocity buffer and is stiffer.
##   READ     — shock_at(world_pos) gives the loudness felt at a point (camera shake, creature panic), and
##              shock_gradient(world_pos) points AWAY from the source (down the shock gradient) so creatures
##              flee the blast without ever knowing where it came from.
##
## The math is the CPU-oracle REFERENCE (gather form — each cell reads neighbours and writes only ITSELF via
## the scratch buffer, then pointer-swaps), so it is order-independent and a future GPU port is bit-for-bit.
## (Explicit types only — no ':=' inferred typing.)

# --- Wave tuning. A future kernels3d/shock3d.glsl would duplicate these EXACTLY ("must match"). ----------
# SPREAD is the fraction of a cell handed to EACH of its 6 neighbours per step; the self coefficient is
# (1 - 6*SPREAD). For STABILITY (no negative self weight, no oscillation) SPREAD must stay <= 1/6 (~0.1666);
# we run it HIGH (near that cap) so the wave radiates several cells per step and reaches nearby creatures
# within a frame or two. LOSS is the fraction of energy removed each step so an acute blast dies in ~1-2 s
# (STEP_DT = 0.1 s → ~10 steps/s; 0.75^15 ≈ 0.013, so ~1.5 s to fade to noise).
const SPREAD: float = 0.15                # per-neighbour diffusion weight (<= 1/6 for stability; HIGH = fast)
const LOSS: float = 0.25                  # fraction of shock energy lost per step (radiate fast, die in ~1-2 s)
const SHOCK_MIN: float = 0.02             # below this a cell counts as SILENT (diagnostics + gradient floor)
const GRAD_MIN: float = 0.001             # below this gradient magnitude shock_gradient returns ZERO (no bias)

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _shock: PackedFloat32Array = PackedFloat32Array()    # OWNED channel: shock/loudness energy per cell
var _scratch: PackedFloat32Array = PackedFloat32Array()  # double buffer (gather reads _shock, writes _scratch)
var _peak_last: float = 0.0                              # diagnostic: peak shock after the last step
var _cells_last: int = 0                                 # diagnostic: audible cells after the last step
var _dirty: bool = false                                 # a fresh emit() this frame → force a step even if quiescent


func setup(field) -> void:
	_f = field
	_shock = PackedFloat32Array()
	_shock.resize(_f._cell_count)
	_scratch = PackedFloat32Array()
	_scratch.resize(_f._cell_count)


## INJECT: add `magnitude` of shock to the cell under a world point. The ONE stimulus every violent event
## feeds (meteor impact, volcano breach, thunder, lightning, a big stampede) — the source is never special-
## cased; propagation + decay do the rest. Deposits into the live `_shock` so the next step() radiates it.
func emit(world_pos: Vector3, magnitude: float) -> void:
	if _f == null or _f._cell_count <= 0 or magnitude <= 0.0:
		return
	var i: int = _cell_index(world_pos)
	if i < 0 or _f._solid[i] != 0:
		return
	_shock[i] += magnitude
	_dirty = true
	# GPU path uploads _shock only when a fresh emit dirtied it (else the GPU radiates it resident); flag the
	# field so this pulse round-trips into the resident buffer next frame.
	_f._shock_dirty = true


## PROPAGATE one step (gather form; deterministic + order-independent, so it mirrors a GPU kernel bit-for-
## bit). Each non-solid cell relaxes toward the average of its 6 neighbours (a SOLID/out-of-bounds neighbour
## REFLECTS, reading this cell's own value, so no shock crosses rock) and loses LOSS of its energy. Writes to
## the scratch buffer, then pointer-swaps it in.
func step() -> void:
	if _f == null or _f._cell_count <= 0:
		return
	if _shock.size() != _f._cell_count:
		_shock.resize(_f._cell_count)
	if _scratch.size() != _f._cell_count:
		_scratch.resize(_f._cell_count)

	# IDLE SKIP: the shock field is quiescent (all cells decayed below audible) and nothing new was injected
	# this frame — a violent event is rare, so most frames there is nothing to propagate. Skip the full-grid
	# gather entirely (a big CPU saving) until the next emit() re-arms it. Correctness: a skipped step leaves
	# the (already-negligible) field untouched, and shock_at reads ~0 either way.
	if not _dirty and _peak_last <= SHOCK_MIN:
		_peak_last = 0.0
		_cells_last = 0
		return
	_dirty = false

	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var solid: PackedByteArray = _f._solid
	var shock: PackedFloat32Array = _shock
	var keep: float = 1.0 - LOSS
	var self_w: float = 1.0 - 6.0 * SPREAD          # self coefficient; >= 0 while SPREAD <= 1/6 (stability)
	var peak: float = 0.0
	var audible: int = 0

	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = (iy * dz + iz) * dx + ix
				if solid[i] != 0:
					_scratch[i] = 0.0                # rock carries no shock energy
					continue
				var s0: float = shock[i]
				# GATHER the 6 neighbours; a solid / out-of-bounds neighbour REFLECTS (reads s0) so energy
				# stays on this side of the wall — shock never transmits through rock (muffling behind ridges).
				var nsum: float = 0.0
				nsum += shock[i - 1] if ix > 0 and solid[i - 1] == 0 else s0
				nsum += shock[i + 1] if ix < dx - 1 and solid[i + 1] == 0 else s0
				nsum += shock[i - dx] if iz > 0 and solid[i - dx] == 0 else s0
				nsum += shock[i + dx] if iz < dz - 1 and solid[i + dx] == 0 else s0
				nsum += shock[i - layer] if iy > 0 and solid[i - layer] == 0 else s0
				nsum += shock[i + layer] if iy < dy - 1 and solid[i + layer] == 0 else s0
				var out: float = keep * (self_w * s0 + SPREAD * nsum)
				_scratch[i] = out
				if out > peak:
					peak = out
				if out > SHOCK_MIN:
					audible += 1

	# Commit the buffer (swap so queries read the fresh state; scratch becomes next step's out buffer).
	var tmp: PackedFloat32Array = _shock
	_shock = _scratch
	_scratch = tmp
	_peak_last = peak
	_cells_last = audible


## GPU-PATH TAIL: the propagation/decay now runs on the GPU (shock3d.glsl inside LAMaterialGPU3D.step()); the
## field folds emit() impulses into _shock, uploads it, and reads the radiated field back. This refreshes the
## SMOKE_SUMMARY/HUD diagnostics (peak + audible-cell count) from that fresh readback instead of step()'s own
## accounting. Staggered by the field (the values change slowly), so it need not scan every frame.
func refresh_diagnostics_from_field() -> void:
	if _f == null or _shock.size() != _f._cell_count:
		return
	var peak: float = 0.0
	var audible: int = 0
	for i in range(_shock.size()):
		var v: float = _shock[i]
		if v > peak:
			peak = v
		if v > SHOCK_MIN:
			audible += 1
	_peak_last = peak
	_cells_last = audible


## READ: shock loudness/energy felt at a world point (0 outside the grid). The camera reads this for tremor
## and creatures read it for panic — proximity + muffling are already baked into the propagated value.
func shock_at(world_pos: Vector3) -> float:
	var i: int = _cell_index(world_pos)
	if i < 0:
		return 0.0
	return _shock[i]


## READ: unit direction pointing AWAY from the shock source at a world point (down the shock gradient), so a
## creature moves along it to FLEE the blast — it never needs to know where the source was. Central-difference
## gradient (a solid/out-of-bounds neighbour reflects, reading this cell's value → no bias into rock); returns
## ZERO when the local shock is flat (no danger direction).
func shock_gradient(world_pos: Vector3) -> Vector3:
	if _f == null or _f._cell_count <= 0:
		return Vector3.ZERO
	var i: int = _cell_index(world_pos)
	if i < 0 or _f._solid[i] != 0:
		return Vector3.ZERO
	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var solid: PackedByteArray = _f._solid
	var shock: PackedFloat32Array = _shock
	var s0: float = shock[i]
	var rem: int = i % layer
	var ix: int = rem % dx
	var iz: int = rem / dx
	var iy: int = i / layer
	var xhi: float = shock[i + 1] if ix < dx - 1 and solid[i + 1] == 0 else s0
	var xlo: float = shock[i - 1] if ix > 0 and solid[i - 1] == 0 else s0
	var zhi: float = shock[i + dx] if iz < dz - 1 and solid[i + dx] == 0 else s0
	var zlo: float = shock[i - dx] if iz > 0 and solid[i - dx] == 0 else s0
	var yhi: float = shock[i + layer] if iy < dy - 1 and solid[i + layer] == 0 else s0
	var ylo: float = shock[i - layer] if iy > 0 and solid[i - layer] == 0 else s0
	# Gradient points UP-shock (toward the source); negate so the result points AWAY (flee direction).
	var grad: Vector3 = Vector3(0.5 * (xhi - xlo), 0.5 * (yhi - ylo), 0.5 * (zhi - zlo))
	if grad.length() < GRAD_MIN:
		return Vector3.ZERO
	return -grad.normalized()


# The flat-array cell index for a world position, or -1 if off-grid / no cells. Clamps into the volume so a
# point on the boundary still resolves (matches the field's own _col_i / wind3_at mapping).
func _cell_index(world_pos: Vector3) -> int:
	if _f == null or _f._cell_count <= 0:
		return -1
	var ix: int = clampi(int(round((world_pos.x - _f._origin.x) / _f._cell_size)), 0, _f._dim_x - 1)
	var iy: int = clampi(int(round((world_pos.y - _f._origin.y) / _f._cell_size)), 0, _f._dim_y - 1)
	var iz: int = clampi(int(round((world_pos.z - _f._origin.z) / _f._cell_size)), 0, _f._dim_z - 1)
	return (iy * _f._dim_z + iz) * _f._dim_x + ix


## Number of cells currently audible (shock above SHOCK_MIN) — diagnostic / SMOKE_SUMMARY `shock_cells`.
func shock_cells() -> int:
	return _cells_last


## Peak shock energy anywhere in the field after the last step (diagnostic / HUD).
func shock_peak() -> float:
	return _peak_last
