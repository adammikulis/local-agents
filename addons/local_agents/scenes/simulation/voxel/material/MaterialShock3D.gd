class_name LAMaterialShock3D
extends RefCounted

## LAMaterialShock3D — the SHOCK / seismic-sound channel of LAMaterialField3D, factored into its own module
## (the field only forwards). A shock is a propagating pressure/sound wave: emit_shock SEEDS amplitude into a
## cell, and the GPU shock_sphere3d kernel (wired in EcoSurfacePass) radiates + attenuates it over the neighbour
## table each step (a blast behind a ridge is muffled emergently — a solid neighbour reflects). The field reads
## the wave back into `_f._shock` so a meteor/earthquake/eruption/stampede shakes the camera and panics creatures.
## This is the substrate primitive Earthquake + Meteor DISSOLVE into: they become seeds/markers that call
## emit_shock, with no dedicated wave code of their own.
##
## Holds NO state of its own — it reaches into the owning LAMaterialField3D (`_f`) for the shared `_shock`
## array, geometry (`world_to_cell`, `cell_world_pos_linear`, `cell_radial`), the sphere neighbour table, and
## the `_shock_dirty` upload flag, exactly as the query/inject modules do. (Explicit types only — no ':=' .)

# A cell whose shock amplitude is over this reads as "actively shaking" (shock_cell_count, tremor gates).
const SHOCK_ACTIVE: float = 0.05
# Seed spill into the immediate neighbour ring so the wave front starts a cell wide (a point seed on a coarse
# grid barely propagates before the loss term eats it). Fraction of the seed magnitude given to each neighbour.
const SEED_NEIGHBOUR_FRACTION: float = 0.5

var _f = null                                            # back-reference to the owning LAMaterialField3D


func setup(field) -> void:
	_f = field


## Inject a shock/sound wave of `magnitude` at a world point — an explosion, thunder-clap, meteor impact,
## eruption blast, or stampede. Seeds the centre cell (+ its neighbour ring) of the GPU shock channel; the
## kernel radiates it outward next step. Dirty-gated: the CPU-seeded amplitude is uploaded before the step.
func emit_shock(world_pos: Vector3, magnitude: float) -> void:
	if magnitude <= 0.0 or _f._shock.size() != _f._cell_count:
		return
	var c: int = _f.world_to_cell(world_pos)
	if c < 0 or c >= _f._cell_count:
		return
	_f._shock[c] = _f._shock[c] + magnitude
	if _f._sphere != null:
		var nbr: PackedInt32Array = _f._sphere.neighbours
		var spill: float = magnitude * SEED_NEIGHBOUR_FRACTION
		for d in range(6):
			var nb: int = nbr[c * 6 + d]
			if nb >= 0 and _f._solid[nb] == 0:
				_f._shock[nb] = _f._shock[nb] + spill
	_f._shock_dirty = true


## Shock amplitude at a world point (0 outside the shell / where the wave has not reached).
func shock_at(world_pos: Vector3) -> float:
	if _f._shock.size() != _f._cell_count:
		return 0.0
	var c: int = _f.world_to_cell(world_pos)
	return _f._shock[c] if c >= 0 else 0.0


## Normalised world direction of INCREASING shock (points back toward the blast) — creatures flee down it, the
## camera shakes along it. Built from the 6-neighbour amplitude differences. Zero where the field is quiet.
func shock_gradient(world_pos: Vector3) -> Vector3:
	if _f._sphere == null or _f._shock.size() != _f._cell_count:
		return Vector3.ZERO
	var c: int = _f.world_to_cell(world_pos)
	if c < 0:
		return Vector3.ZERO
	var pos_c: Vector3 = _f.cell_world_pos_linear(c)
	var s0: float = _f._shock[c]
	var nbr: PackedInt32Array = _f._sphere.neighbours
	var grad: Vector3 = Vector3.ZERO
	for d in range(6):
		var nb: int = nbr[c * 6 + d]
		if nb < 0 or _f._solid[nb] != 0:
			continue
		var dir: Vector3 = _f.cell_world_pos_linear(nb) - pos_c
		if dir.length_squared() < 1.0e-8:
			continue
		grad += dir.normalized() * (_f._shock[nb] - s0)
	if grad.length_squared() < 1.0e-8:
		return Vector3.ZERO
	return grad.normalized()


## Count of open cells actively shaking (amplitude over SHOCK_ACTIVE) — the impact/tremor diagnostic fed into
## SIM_REPORT and the event tracker's impact detector. O(cells), but polled only at snapshot time (not per frame).
func shock_cell_count() -> int:
	if _f._shock.size() != _f._cell_count:
		return 0
	var n: int = 0
	for c in _f._cell_count:
		if _f._solid[c] == 0 and _f._shock[c] > SHOCK_ACTIVE:
			n += 1
	return n
