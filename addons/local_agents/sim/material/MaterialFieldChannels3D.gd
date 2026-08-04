class_name LAMaterialFieldChannels3D
extends RefCounted

## LAMaterialFieldChannels3D: the per-cell CHANNEL accessors of LAMaterialField3D (the atmospheric gases,
## living biomass, the decomposer's detritus deposit, and the phase-channel debug reads), factored out of the
## extract-only field hub. Same pattern as the query / atmos / ledger / scent modules: no state of its own, it
## reaches into the owning field `_f` for the shared per-cell arrays and geometry.
##
## Everything here is a TRUE-3D world-point read of a channel the GPU owns and reads back, with no 2.5D column
## walk, no per-species special case. The two that carry real rules are:
##   - breathable_o2_at: air is displaced by water (a lung drowns) and rock holds none, but a ground-standing
##     creature whose head cell QUANTISES into the surface rock is not buried, so step radially outward to the
##     first open cell. Drowning + smoke suffocation stay 0; only a truly encased creature reads 0.
##   - is_submerged_at: the same cell test inverted, which is what a gill-breather needs.
## Both fall straight out of the substrate, which is why lungs/gills need no can_fly or depth_at branch.
##
## Demand-gated channels (co2, lava) self-wake their readback via `_f._gpu.request_channel(...)` on query, because
## there is no producer-side event to hook them to. (Explicit types only, no ':=' inferred typing.)

var _f = null                                            # back-reference to the owning LAMaterialField3D


func setup(field) -> void:
	_f = field


# --- Emergent atmospheric OXYGEN: O₂ level at a point + depletion diagnostics -------------------------

func o2_at(x: float, y: float, z: float) -> float:
	if _f._sphere != null:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._o2[c] if c >= 0 else LAMaterialField3D.O2_AMBIENT
	return LAMaterialField3D.O2_AMBIENT


## BREATHABLE oxygen at a TRUE-3D world point — the cell's O₂, but ZERO once WATER fills the cell (water
## displaces air) or the cell is rock. One 3D read that lets a lung suffocate underwater OR in O₂-depleted
## smoke, with altitude respected for free (a flying bird's head cell holds no water; a diver's does) — no
## 2.5D depth column, no can_fly special-case. Gills invert it (see is_submerged_at). Above the volume = open sky.
func breathable_o2_at(x: float, y: float, z: float) -> float:
	var c: int = _f.world_to_cell(Vector3(x, y, z))
	if c < 0:
		return LAMaterialField3D.O2_AMBIENT   # above the atmosphere shell = open sky
	# Water fills the cell → air is displaced → a lung drowns. Real; keep it (drowning + smoke stay 0).
	if _f._water[c] >= LAMaterialField3D.MAX_MASS * 0.5:
		return 0.0
	# ROCK holds no air — but a ground-standing creature whose head cell QUANTISES into the surface rock
	# (body size 0.5 ≪ cell size 5) is NOT buried; it breathes the thin air resting on the ground. Step
	# radially outward to the first open cell and read ITS O₂ (the true surface air — still 0 if choked by
	# smoke there). Only a creature truly encased in rock (no open cell outward within reach) reads 0. This
	# fixes land animals wrongly suffocating on solid ground without breaking drowning/smoke suffocation.
	if _f._solid[c] != 0:
		if _f._sphere == null:
			return 0.0                        # box mode (unused in the sim): keep the strict rule
		var steps: int = 0
		while _f._solid[c] != 0 and steps < 4:
			var up_c: int = _f._sphere.neighbours[c * 6 + 1]   # N_OUT = 1 (radially outward)
			if up_c < 0:
				return 0.0                    # reached space while still in rock → encased
			c = up_c
			steps += 1
		if _f._solid[c] != 0 or _f._water[c] >= LAMaterialField3D.MAX_MASS * 0.5:
			return 0.0
	return _f._o2[c]


## Is the TRUE-3D cell at this world point underwater (over half-full of water)? What a gill-breather needs
## (and what tells a lung it is submerged). Solid rock reads not-submerged (no water there).
func is_submerged_at(x: float, y: float, z: float) -> bool:
	var c: int = _f.world_to_cell(Vector3(x, y, z))
	return c >= 0 and _f._solid[c] == 0 and _f._water[c] >= LAMaterialField3D.MAX_MASS * 0.5


# Open-cell O₂ min / mean over the GPU readback (_o2). Proves the sky-refill + transport keep the open air
# oxygenated and expose sealed-cavity draw-down. Falls back to ambient when no field is resident.
func o2_min_open() -> float:
	if _f._o2.size() != _f._cell_count or _f._cell_count <= 0:
		return LAMaterialField3D.O2_AMBIENT
	var solid: PackedByteArray = _f._solid
	var water: PackedFloat32Array = _f._water
	var o2: PackedFloat32Array = _f._o2
	var flooded: float = LAMaterialField3D.MAX_MASS * 0.5
	var mn: float = 1.0e20
	var n: int = 0
	for c in _f._cell_count:
		if solid[c] != 0 or water[c] >= flooded:
			continue
		mn = minf(mn, o2[c])
		n += 1
	return mn if n > 0 else LAMaterialField3D.O2_AMBIENT


func o2_avg() -> float:
	if _f._o2.size() != _f._cell_count or _f._cell_count <= 0:
		return LAMaterialField3D.O2_AMBIENT
	var solid: PackedByteArray = _f._solid
	var water: PackedFloat32Array = _f._water
	var o2: PackedFloat32Array = _f._o2
	var flooded: float = LAMaterialField3D.MAX_MASS * 0.5
	var sum: float = 0.0
	var n: int = 0
	for c in _f._cell_count:
		if solid[c] != 0 or water[c] >= flooded:
			continue
		sum += o2[c]
		n += 1
	return sum / float(n) if n > 0 else LAMaterialField3D.O2_AMBIENT


# --- Airborne DUST (the mineral ledger's "airborne" phase) ---------------------------------------------

## Airborne wind-lofted dust at a world point. `dust` is demand-gated exactly like `co2`, so the query
## self-wakes its readback the same way — without that, a caller reads whatever the last crater left in the
## mirror, or (far more often) the all-zero allocation. LAMaterialField3D.dust_at used to be a bare
## `return 0.0`; this is its real body.
func dust_at(x: float, y: float, z: float) -> float:
	if _f._gpu != null:
		_f._gpu.request_channel("dust")
	if _f._sphere != null and _f._dust.size() == _f._cell_count:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._dust[c] if c >= 0 else 0.0
	return 0.0


# --- Emergent CARBON DIOXIDE (second gas channel): CO₂ level at a point + build-up diagnostics ---------

func co2_at(x: float, y: float, z: float) -> float:
	if _f._gpu != null:
		_f._gpu.request_channel("co2")   # co2 is demand-gated; no producer-side event to hook, so query self-wakes it
	if _f._sphere != null:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._co2[c] if c >= 0 else 0.0
	return 0.0


func co2_peak() -> float:
	if _f._gpu != null:
		_f._gpu.request_channel("co2")
	if _f._co2.size() != _f._cell_count or _f._cell_count <= 0:
		return 0.0
	var solid: PackedByteArray = _f._solid
	var co2: PackedFloat32Array = _f._co2
	var mx: float = 0.0
	for c in _f._cell_count:
		if solid[c] == 0:
			mx = maxf(mx, co2[c])
	return mx


func co2_avg() -> float:
	if _f._gpu != null:
		_f._gpu.request_channel("co2")
	if _f._co2.size() != _f._cell_count or _f._cell_count <= 0:
		return 0.0
	var solid: PackedByteArray = _f._solid
	var co2: PackedFloat32Array = _f._co2
	var sum: float = 0.0
	var n: int = 0
	for c in _f._cell_count:
		if solid[c] != 0:
			continue
		sum += co2[c]
		n += 1
	return sum / float(n) if n > 0 else 0.0


# --- Emergent LIVING BIOMASS (MaterialReactions3D R19/R20): CO₂ fixed into plant matter on the GPU -----

func biomass_at(x: float, y: float, z: float) -> float:
	if _f._sphere != null:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._biomass[c] if (c >= 0 and _f._biomass.size() == _f._cell_count) else 0.0
	return 0.0


## Total living biomass over every open cell — the emergent-growth spot check (should rise then plateau, not
## explode; bounded by the CO₂ budget + respiration). Fed into SIM_REPORT.
func biomass_total() -> float:
	if _f._biomass.size() != _f._cell_count or _f._cell_count <= 0:
		return 0.0
	var solid: PackedByteArray = _f._solid
	var biomass: PackedFloat32Array = _f._biomass
	var sum: float = 0.0
	for c in _f._cell_count:
		if solid[c] == 0:
			sum += biomass[c]
	return sum


## `deposit_detritus` USED TO LIVE HERE AND DID NOTHING. It wrote `_f._detritus[c] += amount` — the CPU
## mirror — and that mirror reaches the GPU exactly once, through the one-shot `_detritus_seed_dirty` upload
## in LAMaterialFieldSphereStep3D, which is cleared immediately so the GPU-evolved detritus is never
## clobbered. Every drain that requests the channel then overwrites the mirror with the readback. So from the
## moment the decomposer loop was wired, every rotting carcass and every dropping was DELETED rather than
## returned to the soil, and `detritus_peak` reported the seed. Deleted 2026-08-03; the working version is
## LAMaterialFieldBiota3D.litter, which parks the credit on the device injection queue like every other
## CPU-side write into a GPU-resident channel.
## `respire_at` USED TO LIVE HERE TOO, AND IT WAS DEAD FOR THE SAME REASON. It applied R20's aerobic Liebig
## cap correctly, reading the stoichiometry straight off LABioRecords — that part was right and is kept, in
## LAMaterialFieldBiota3D.respire. What was wrong is where it wrote: `_f._o2[c]`, `_f._co2[c]` and
## `_f._detritus[c]` are CPU MIRRORS, and MaterialFieldSphereStep3D overwrites all three wholesale from the
## GPU readback every drain. So every breath an animal ever took debited nothing. Deleted 2026-08-03 with
## `deposit_detritus`; the working version parks both the O2 debit and the CO2/detritus credit on the device
## injection queue.


# Per-cell debug readers for the phase channels (mirror biomass_at/co2_at): molten mineral, bedrock
# fraction, and pre-lightning electrification. Pure reads for the DebugPanel field-view heatmaps.
func lava_at(x: float, y: float, z: float) -> float:
	if _f._sphere != null:
		if _f._gpu != null:
			_f._gpu.request_channel("lava")   # keep lava readback hot while something queries it
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._lava[c] if (c >= 0 and _f._lava.size() == _f._cell_count) else 0.0
	return 0.0


func rock_fill_at(x: float, y: float, z: float) -> float:
	if _f._sphere != null:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._rock_fill[c] if (c >= 0 and _f._rock_fill.size() == _f._cell_count) else 0.0
	return 0.0


func charge_at(x: float, y: float, z: float) -> float:
	if _f._sphere != null:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._charge[c] if (c >= 0 and _f._charge.size() == _f._cell_count) else 0.0
	return 0.0


# --- Emergent DECOMPOSER loop: detritus (dead matter) → fungus → CO₂ + soil fertility -----------------
#
# THESE FOUR WERE HARDCODED ZEROS. `fungus_at`, `fungus_peak`, `fungus_cells` and `detritus_peak` sat on the
# field hub as literal `return 0.0` / `return 0` bodies, and MaterialFieldReport3D pipes three of them
# straight into SIM_REPORT — so the decomposer half of the carbon loop has published a constant zero for the
# life of every run while `fungus_total` beside it read real values. The stub was honest when it was written:
# `detritus` and `fungus` were in NO readback set, so the CPU mirrors held their all-zero allocation and a
# real body would have returned zero anyway. Both channels became demand-gated on 2026-08-03
# (LAMaterialSphereGPU3D.SITUATIONAL_CHANNELS), so the data is there now and these read it.
#
# Both are demand-gated, so every reader self-wakes its channel the way co2_at does — there is no
# producer-side event to hook a request to.

## Presence thresholds, taken from the substrate's OWN rule rather than an invented epsilon. The kernel grows
## fungus only where detritus is above DETRITUS_MIN and kills the colony back below it
## (kernels3d/fungus_sphere3d.glsl:38-39, :72, :97), so "this cell has a colony" / "this cell has food" means
## the same thing to the gauge as to the physics that produced it. FUNGUS_MIN is declared in that kernel and
## never used there; this is its consumer.
const FUNGUS_PRESENT: float = 0.02        # == fungus_sphere3d.glsl FUNGUS_MIN
const DETRITUS_PRESENT: float = 0.05      # == fungus_sphere3d.glsl DETRITUS_MIN


func fungus_at(x: float, y: float, z: float) -> float:
	if _f._gpu != null:
		_f._gpu.request_channel("fungus")
	if _f._sphere != null:
		var c: int = _f.world_to_cell(Vector3(x, y, z))
		return _f._fungus[c] if (c >= 0 and _f._fungus.size() == _f._cell_count) else 0.0
	return 0.0


## Decomposer EXTENT and INTENSITY for both substances, in ONE O(cells) pass on the report's snapshot cadence
## (the three separate scans the old signatures implied would have been three sweeps of the grid for four
## numbers).
##
## SHAPE, because a peak alone is one sample used to argue about a distribution: `*_peak` cannot tell a single
## thick bloom from a planet-wide mat, so extent (`*_cells`) is reported beside it and
## LAMaterialFieldElementInventory3D already carries the totals (`fungus_total`, `carbon_detritus`). Total + extent
## + peak is the smallest set that separates "thin everywhere" from "one patch". `detritus_cells` is NEW —
## detritus had a peak and no extent, so nothing in the report said whether the food the fungus eats was
## spread over the planet or piled in one place, which is the whole question about a decomposer.
##
## Masked on OPEN cells, the same mask the kernel and the mass budget use: fungus_sphere3d zeroes fungus in
## rock, and detritus inside rock has been BURIED rather than made available, so counting it would report food
## the decomposer cannot reach.
func decomposer_stats() -> Dictionary:
	if _f._gpu != null:
		_f._gpu.request_channel("fungus")
		_f._gpu.request_channel("detritus")
	var out: Dictionary = {"fungus_peak": 0.0, "fungus_cells": 0, "detritus_peak": 0.0, "detritus_cells": 0}
	var cc: int = _f._cell_count
	if cc <= 0:
		return out
	var solid: PackedByteArray = _f._solid
	var fung: PackedFloat32Array = _f._fungus
	var det: PackedFloat32Array = _f._detritus
	var has_fung: bool = fung.size() == cc
	var has_det: bool = det.size() == cc
	if solid.size() != cc or not (has_fung or has_det):
		return out
	var f_peak: float = 0.0
	var f_n: int = 0
	var d_peak: float = 0.0
	var d_n: int = 0
	for c in cc:
		if solid[c] != 0:
			continue
		if has_fung:
			var fv: float = fung[c]
			f_peak = maxf(f_peak, fv)
			if fv >= FUNGUS_PRESENT:
				f_n += 1
		if has_det:
			var dv: float = det[c]
			d_peak = maxf(d_peak, dv)
			if dv >= DETRITUS_PRESENT:
				d_n += 1
	out["fungus_peak"] = f_peak
	out["fungus_cells"] = f_n
	out["detritus_peak"] = d_peak
	out["detritus_cells"] = d_n
	return out
