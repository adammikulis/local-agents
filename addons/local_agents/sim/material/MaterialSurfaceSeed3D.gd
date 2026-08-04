class_name LAMaterialSurfaceSeed3D
extends RefCounted

## LAMaterialSurfaceSeed3D seeds + maintains the GROUND-SURFACE substrate channels of LAMaterialField3D that
## are otherwise allocated to zeros and so never come alive, factored into its own module (the field hub only
## wires + forwards). Two channels, both "what sits on the ground":
##
##   * FUEL (combustion): the GPU fire kernel (fire_sphere3d.glsl) GATES on fuel > 0, so a zero-filled fuel
##     channel means combustion can NEVER ignite (no wildfire, no CO₂ from burning, no fuel-driven O₂ draw-down).
##     seed_initial() lays the flammable share of the ground's initial dead organic matter on every open
##     ground-surface cell so a heat source (lightning/lava/meteor) can ignite from frame 0; post_readback()
##     tops it up from the emergent LIVING BIOMASS channel on a cadence (that standing vegetation IS what
##     becomes litter), as a CONSERVING transfer.
##
##   * DETRITUS (decomposer substrate): real soil holds dead organic matter; a zero-filled detritus channel
##     leaves the detritus→fungus→CO₂+FERTILITY loop with no substrate to bootstrap from (fungus only grows on
##     detritus), so soil fertility stays flat 0 for hundreds of steps until biomass respiration slowly builds
##     it. seed_initial() lays a modest baseline of soil organic matter on the same ground-surface cells so the
##     decomposer runs from the start and the (now read-back) fertility channel actually reflects the loop.
##
## ===== THIS MODULE USED TO MAKE CARBON APPEAR, IN TWO WAYS. FIXED 2026-08-03. ==============================
##
## 1. THE SEED WAS A FLAT `BASELINE_FUEL = 2.0` PER GROUND CELL, in addition to the detritus seed — about
##    9,600 mass units of carbon-bearing matter stamped onto the planet at world-gen (measured:
##    `fuel_open_total` 9540 on a 600-frame baseline). `fire_sphere3d.glsl` then burns that fuel into CO₂, and
##    CO₂ *is* inside the carbon ledger (`carbon_total` = co2 + biomass + detritus) while `fuel` is only a memo
##    line beside it. So every unit burnt was carbon entering the books from outside them. For scale, the
##    planet's entire standing crop is `biomass_open_total` ~6.5 units: the fuel seed was fifteen hundred
##    times the whole biosphere.
##    Now the litter is a stated FRACTION of the soil organic matter it comes from (LITTER_FLAMMABLE_FRAC of
##    BASELINE_DETRITUS), which cuts it to 216 units — a 97.8% reduction — and ties it to something real
##    instead of a number. What remains is small, declared and reported (`fuel_seeded`).
##
## 2. THE REFILL CONVERTED BIOMASS INTO FUEL WITHOUT DEBITING BIOMASS — `_f._fuel[c] = biomass[c] * GAIN`,
##    every 40 steps, forever, with the biomass left standing exactly where it was. Litter really is made of
##    the plant it fell from, so this is now a conserving `biomass → fuel` transfer resolved on device
##    (LAMaterialFieldHeatQueue3D.carbon_transfer): what the cell's fuel gains, its standing biomass loses.
##    It also stopped writing the CPU `_fuel` mirror and raising `_fuel_dirty`, which uploaded the WHOLE fuel
##    channel over the live GPU buffer and so discarded whatever combustion had done since the last readback —
##    the same rewind `add_vapor` and `add_heat` were moved off.
##
## Holds NO field state: it reaches into the owning LAMaterialField3D (`_f`) for the per-cell arrays + the
## sphere neighbour table, exactly as the query/inject/step modules do.
## (Explicit types only, no ':=' inferred typing.)

# Soil organic matter on a bare ground-surface cell at world activation — the decomposer's substrate, and a
# declared initial condition for "this planet was not born sterile". Sized so it clears the fungus kernel's
# DETRITUS_MIN = 0.05 with room to spare, which is what the decomposer loop needs to bootstrap at all. It is
# INSIDE the carbon ledger (`carbon_total` sums co2 + biomass + detritus; SIM_REPORT shows it as
# `carbon_first` 720 = 4800 ground cells x 0.15), so it is declared, counted, and unchanged by this fix.
const BASELINE_DETRITUS: float = 0.15
# The flammable LITTER lying on top of that soil, as a fraction of it. Fire-behaviour models separate FINE
# fuels — litter, cured grass, small twigs, the material that carries a spreading flame front — from the
# coarse debris and buried humus that do not, and the fine fraction of a surface dead-fuel load is measured at
# roughly 20-40% in temperate litter. 30% is the middle. It is a ratio between two real components of ground
# organic matter, not a knob for how much fuel there is.
#
# WHY THIS IS A FRACTION AND NOT AN ABSOLUTE, and why it is not taken OUT of the detritus: the violation being
# fixed is a flat BASELINE_FUEL = 2.0, which is 9,600 mass units — fifteen hundred times the planet's entire
# standing crop — sitting outside the carbon books and burning into CO2 that is inside them. Tying the litter
# to the soil organic matter it comes from cuts that to 216 units, a 97.8% reduction, WITHOUT touching the
# declared detritus seed. An earlier version of this fix carved the litter out of the detritus instead, which
# conserved carbon at the seed but cut the decomposer's substrate 30% and, measured on --planet-only,
# propagated straight through fungus (5.51 -> 2.90) and fertility (0.36 -> 0.14) to halve the standing crop
# (biomass_open_total 6.65 -> 3.07). That was a collateral change to the world, not a conservation fix.
#
# WHAT IS STILL OWED, and it is not this module's to fix: those 216 units are carbon-bearing and
# `MaterialFieldElementInventory3D` counts `fuel_open_total` only as a MEMO LINE beside `carbon_total`, so burning
# fuel still moves carbon from outside the books to inside them. The seed is now small, declared and reported
# (`fuel_seeded`), but the accounting gap closes properly only when the budget module adds fuel to the carbon
# sum — that file is another track's.
const LITTER_FLAMMABLE_FRAC: float = 0.30
# The standing litter a cell's LIVING biomass supports, as a fraction of it. Annual litterfall runs 5-10% of
# standing biomass and litter sits on the ground for one to three years before it decomposes, so the standing
# litter layer settles near 10-30% of live biomass. 0.20 is the middle. This is the CAP on the refill below —
# a cell cannot hold more litter than its own vegetation can shed — and the transfer that fills it debits the
# biomass it came from, so the cap bounds a MOVE, never a source.
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


## The organic seed, split between the two channels it belongs in, on every open GROUND-surface cell (an open
## cell whose inward-radial neighbour, slot 0, is solid rock — i.e. soil and litter sitting on the ground).
## Marks both channels dirty so the hub uploads them next step; this runs at world activation, before any GPU
## step has happened, so there is nothing for the whole-channel upload to rewind here.
func seed_initial() -> void:
	if _f == null or _f._sphere == null or _f._fuel.size() != _f._cell_count:
		return
	var nbr: PackedInt32Array = _f._sphere.neighbours
	if nbr.size() < _f._cell_count * 6:
		return
	var has_detritus: bool = _f._detritus.size() == _f._cell_count
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
	_f._fuel_dirty = true
	_f._detritus_seed_dirty = has_detritus


## Top the litter up from the emergent biomass channel on the coarse cadence, as a CONSERVING TRANSFER: a
## cell whose vegetation has regrown sheds litter, and the biomass it shed is debited from the same cell. Run
## after each readback (biomass + fuel are freshly scattered) so the ask is sized against current values; the
## move itself is resolved on device in the queue's flush window, where a debit can never exceed what is
## really there. Detritus is NOT refilled here — it is GPU-owned after the one-shot seed (respiration credits
## it, the decompose record debits it), so re-uploading would clobber that on-device evolution.
## fuel is demand-gated (SITUATIONAL_CHANNELS): pre-warm its readback a few drains ahead of REFILL_EVERY so
## it's genuinely fresh by the time this reads it, instead of requesting-and-reading the same drain.
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


## SIM_REPORT provider. `fuel_seeded` is the one-off world-gen initial condition (a declared quantity, so it
## can be subtracted when judging whether the carbon books close); `fuel_from_biomass` is the mass the litter
## refill has ASKED the biomass channel for over the run, against which `carbon_inject_moved` in the injection
## ledger is what the device actually moved. A gap between them is biomass the planet did not have.
func report() -> Dictionary:
	return {
		"fuel_seeded": snappedf(_seeded_fuel, 0.01),
		"fuel_from_biomass": snappedf(_moved_to_fuel, 0.0001),
	}
