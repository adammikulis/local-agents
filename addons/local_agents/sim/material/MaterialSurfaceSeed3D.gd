class_name LAMaterialSurfaceSeed3D
extends RefCounted


# DETRITUS_MIN = 0.05 with room to spare, which is what the decomposer loop needs to bootstrap at all. It is
const BASELINE_DETRITUS: float = 0.15
const LITTER_FLAMMABLE_FRAC: float = 0.30
const LITTER_FROM_BIOMASS: float = 0.20
# Refill cadence (GPU field steps between biomass→fuel top-ups). A burning cell spends ~BURN_RATE per step, so
# topping up every N steps keeps a standing fire fed by its living vegetation instead of self-extinguishing the
# moment its litter is spent — the fire persists as long as biomass regrows under it, and stops when it does not.
const REFILL_EVERY: int = 40
# Drains ahead of REFILL_EVERY to start requesting the (demand-gated) fuel channel, so it has already been
# read back fresh by the time the refill below runs -- must be >= the driver's CHANNEL_HOLD_DRAINS (20).
const FUEL_REQUEST_LEAD: int = 20

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _refill_tick: int = 0
var _seeded_fuel: float = 0.0                            # cumulative fuel laid by the world-gen seed
var _moved_to_fuel: float = 0.0                          # cumulative biomass ASKED to become litter


func setup(field) -> void:
	_f = field
	LASimReport.register(Callable(self, "report"))


## cell whose inward-radial neighbour, slot 0, is solid rock — i.e. soil and litter sitting on the ground).
func seed_initial() -> void:
	if _f == null or _f._sphere == null or _f._fuel.size() != _f._cell_count:
		return
	var nbr: PackedInt32Array = _f._sphere.neighbours
	if nbr.size() < _f._cell_count * 6:
		return
	var has_detritus: bool = _f._detritus.size() == _f._cell_count
	var has_org: bool = _f._org_h.size() == _f._cell_count and _f._org_o.size() == _f._cell_count
	var fuel_share: float = BASELINE_DETRITUS * LITTER_FLAMMABLE_FRAC
	for c in _f._cell_count:
		if _f._solid[c] != 0:
			continue
		var down: int = nbr[c * 6 + 0]
		if down >= 0 and _f._solid[down] != 0:
			_f._fuel[c] = fuel_share
			_seeded_fuel += fuel_share
			if has_detritus:
				_f._detritus[c] = maxf(_f._detritus[c], BASELINE_DETRITUS)
			# Seeded litter is FRESH: CH2O, so 2 H and 1 O per carbon over the whole dead pool in this cell.
			if has_org:
				var pool: float = _f._fuel[c] + (_f._detritus[c] if has_detritus else 0.0)
				_f._org_h[c] = pool * LASubstances.fresh_litter_per_carbon("H")
				_f._org_o[c] = pool * LASubstances.fresh_litter_per_carbon("O")
	_f._fuel_dirty = true
	_f._detritus_seed_dirty = has_detritus
	_f._organic_seed_dirty = has_org


func post_readback() -> void:
	_refill_tick += 1
	if _refill_tick >= REFILL_EVERY - FUEL_REQUEST_LEAD and _f != null and _f._gpu != null:
		_f._gpu.request_channel("fuel")
	if _refill_tick < REFILL_EVERY:
		return
	_refill_tick = 0
	if _f == null or _f._fuel.size() != _f._cell_count or _f._biomass.size() != _f._cell_count:
		return
	if _f._inject == null or not _f._inject.queue.has_method("carbon_transfer"):
		return
	var cells: PackedInt32Array = PackedInt32Array()
	var amounts: PackedFloat32Array = PackedFloat32Array()
	for c in _f._cell_count:
		if _f._solid[c] != 0:
			continue
		# The litter this cell's own standing vegetation supports, minus what it already has. Nothing is added
		# where the ground is bare: a burnt-out cell with no biomass under it stays ash, which is what makes
		# the fuel ledger fall where fire ran and only recover as the vegetation does.
		var target: float = _f._biomass[c] * LITTER_FROM_BIOMASS
		var need: float = target - _f._fuel[c]
		if need <= 0.0:
			continue
		cells.append(c)
		amounts.append(need)
		_moved_to_fuel += need
	if cells.size() > 0:
		_f._inject.queue.carbon_transfer("biomass", cells, amounts, "fuel", cells)


func report() -> Dictionary:
	return {
		"fuel_seeded": snappedf(_seeded_fuel, 0.01),
		"fuel_from_biomass": snappedf(_moved_to_fuel, 0.0001),
	}
