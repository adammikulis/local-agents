class_name LAMaterialScent3D
extends RefCounted

## LAMaterialScent3D — the SCENT / chemical-signal channel of LAMaterialField3D, factored into its own module
## (the field only forwards). Scent is a diffusing/advecting chemical cue: deposit() SEEDS a cell of one of the
## five channels (prey / predator / blood / food / alarm), and the GPU scent kernel spreads + attenuates it over
## the neighbour table each step (a scent riding the real wind washes downwind and out in the rain — emergent).
## The field reads the five planes back into `_f._scent` so senses/cognition can smell a gradient: prey follow a
## food/prey trail, scavengers home on blood/carcass food, and predators track prey while prey flee alarm.
## This is the substrate primitive marking/wounds/carcasses DISSOLVE into: a wound calls deposit(BLOOD), a
## carcass deposit(FOOD), waste deposit(PREY/FOOD) — with no dedicated trail code of their own.
##
## Holds NO state of its own — it reaches into the owning LAMaterialField3D (`_f`) for the shared `_scent`
## array, geometry (`world_to_cell`, `cell_world_pos_linear`), the sphere neighbour table, and the
## `_scent_dirty` upload flag, exactly as the shock/charge modules do. The five channels are packed into ONE
## flat array, plane-major: index = channel * _f._cell_count + cell. (Explicit types only — no ':=' .)

# A cell whose scent density is over this reads as "carrying meaningful scent" (scent_cell_count diagnostic).
const SCENT_ACTIVE: float = 0.02
# Seed spill into the immediate neighbour ring so a deposit starts a cell wide (a point seed on a coarse grid
# barely diffuses before the loss term eats it). Fraction of the seed magnitude given to each open neighbour.
const SEED_NEIGHBOUR_FRACTION: float = 0.5

var _f = null                                            # back-reference to the owning LAMaterialField3D


func setup(field) -> void:
	_f = field


## Total packed length of the five-plane scent buffer for the current grid (channel-major).
func _packed_size() -> int:
	return LAMaterialField3D.SCENT_CHANNELS * _f._cell_count


## Deposit `amount` of one scent `channel` (SCENT_PREY/PREDATOR/BLOOD/FOOD/ALARM) at a world point — a wound
## bleeding, a carcass advertising food, a creature marking with waste. Seeds the centre cell (+ its neighbour
## ring) of that plane; the GPU scent kernel diffuses it outward next step. Dirty-gated: the CPU-seeded density
## is uploaded before the step.
func deposit(world_pos: Vector3, channel: int, amount: float) -> void:
	if amount <= 0.0 or channel < 0 or channel >= LAMaterialField3D.SCENT_CHANNELS:
		return
	if _f._scent.size() != _packed_size():
		return
	var c: int = _f.world_to_cell(world_pos)
	if c < 0 or c >= _f._cell_count:
		return
	var base: int = channel * _f._cell_count
	_f._scent[base + c] = _f._scent[base + c] + amount
	if _f._sphere != null:
		var nbr: PackedInt32Array = _f._sphere.neighbours
		var spill: float = amount * SEED_NEIGHBOUR_FRACTION
		for d in range(6):
			var nb: int = nbr[c * 6 + d]
			if nb >= 0 and _f._solid[nb] == 0:
				_f._scent[base + nb] = _f._scent[base + nb] + spill
	_f._scent_dirty = true


## Scent density of a channel at a world point (0 outside the shell / where the trail has not reached).
func scent_at(world_pos: Vector3, channel: int) -> float:
	if channel < 0 or channel >= LAMaterialField3D.SCENT_CHANNELS or _f._scent.size() != _packed_size():
		return 0.0
	var c: int = _f.world_to_cell(world_pos)
	return _f._scent[channel * _f._cell_count + c] if c >= 0 else 0.0


## Normalised world direction of INCREASING scent of a channel (points UP the gradient — toward the source).
## Predators track prey up it, prey flee alarm down it, scavengers home on blood/food. Built from the
## 6-neighbour density differences (FULL 3D radial finite difference, not XZ-flattened). Zero where the plane is
## quiet.
func scent_gradient(world_pos: Vector3, channel: int) -> Vector3:
	if _f._sphere == null or channel < 0 or channel >= LAMaterialField3D.SCENT_CHANNELS:
		return Vector3.ZERO
	if _f._scent.size() != _packed_size():
		return Vector3.ZERO
	var c: int = _f.world_to_cell(world_pos)
	if c < 0:
		return Vector3.ZERO
	var base: int = channel * _f._cell_count
	var pos_c: Vector3 = _f.cell_world_pos_linear(c)
	var s0: float = _f._scent[base + c]
	var nbr: PackedInt32Array = _f._sphere.neighbours
	var grad: Vector3 = Vector3.ZERO
	for d in range(6):
		var nb: int = nbr[c * 6 + d]
		if nb < 0 or _f._solid[nb] != 0:
			continue
		var dir: Vector3 = _f.cell_world_pos_linear(nb) - pos_c
		if dir.length_squared() < 1.0e-8:
			continue
		grad += dir.normalized() * (_f._scent[base + nb] - s0)
	if grad.length_squared() < 1.0e-8:
		return Vector3.ZERO
	return grad.normalized()


## Count of open cells carrying meaningful scent in ANY channel (density over SCENT_ACTIVE) — the airborne-scent
## diagnostic fed into SMOKE_SUMMARY. O(channels*cells), but polled only at snapshot time (not per frame).
func scent_cell_count() -> int:
	if _f._scent.size() != _packed_size():
		return 0
	var n: int = 0
	var channels: int = LAMaterialField3D.SCENT_CHANNELS
	for c in _f._cell_count:
		if _f._solid[c] != 0:
			continue
		for ch in channels:
			if _f._scent[ch * _f._cell_count + c] > SCENT_ACTIVE:
				n += 1
				break
	return n
