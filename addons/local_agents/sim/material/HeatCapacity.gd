class_name LAHeatCapacity
extends RefCounted

## THE ONE GDSCRIPT DEFINITION OF A CELL'S VOLUMETRIC HEAT CAPACITY — the CPU twin of
## kernels3d/rc_shared.glsli, and the only place on this side of the GPU boundary that is allowed to write
## the mix down.
##
## WHY IT EXISTS. `rc_of` was written FIVE times in FOUR incompatible versions in GLSL; that was fixed by
## rc_shared.glsli. It was ALSO written four more times in GDScript, and that was not:
##   LAMaterialFieldEnergyLedger3D  — the energy STOCK
##   LAMaterialFieldEnergyBudget3D  — the BOOKED solar and longwave terms
##   LAMaterialFieldInject3D        — `_cell_heat_capacity`, what a joule of injected heat buys
##   LAMaterialFieldGeotherm3D      — the core boundary flux
## The first two are the two halves of one subtraction. The ledger differences a BOOKED number against a
## STOCK, so when those two disagree about what a cell is made of, part of the reported drift is two
## instruments arguing rather than the planet losing heat. That is not hypothetical: unifying the ledger's
## copy with the kernels' took the measured drift from 7.4% to 12.8% of the planet's thermal stock, and the
## Budget copy — the BOOKED side — was still the pre-unification model with a `solid` early-return and no
## lava or organic term. A gate on the constants cannot see this, because every copy read the right
## constants and put them in a different formula.
##
## HOW IT STAYS EQUAL TO THE GLSL. It cannot include a `.glsli`, so it is a transcription, and a
## transcription is a copy that has been told not to drift. Two things hold it:
##   1. scripts/check_heat_capacity_ssot.sh fails the build if VOL_HEAT_CAP_*_J_M3K is read anywhere but
##      here, or if an RC_* constant is declared outside rc_shared.glsli. That gates the SHAPE — which is
##      what drifted — rather than the values, which never did.
##   2. Any edit to rc_shared.glsli's `rc_of` must change `_mix` below in the same commit. There is one
##      function here and one there; keep them one edit apart.
##
## THE GROUPING IS BY SUBSTANCE, NOT BY CHANNEL, and that is the part that matters. A channel is not a
## material, it is a PLACE a material can be. Five channels hold silicate, four hold H2O in three phases,
## four hold cellulose. Grouping by substance means a new channel joins the group it belongs to instead of
## needing a constant of its own — and it is why `soil` needs no constant: groundwater is water.
## (Explicit types only, no ':=' inferred typing.)

## Channel -> substance group. THE ORDER OF THIS TABLE IS THE MODEL. Adding a channel that holds matter and
## leaving it out of here makes every gram that crosses into it delete its own thermal mass, which is the
## defect this whole file was written to close: `rc_of` counted seven of these fifteen, and the missing eight
## were measured at twice the size of everything the temperature kernels do put together.
## `rock_fill` is a SATURATION of the cell's rock matrix, not a volume fraction of mineral, so it is the one
## silicate channel that must be scaled by (1 - phi) before it can be mixed with the rest. Kept separate from
## SILICATE for exactly that reason — see the note in `mix`.
const MATRIX: PackedStringArray = ["rock_fill"]
## The loose silicate phases. These ARE volume fractions already and carry no matrix of their own, so phi
## does not apply to them.
const SILICATE: PackedStringArray = ["lava", "sediment", "susp", "dust"]
const WATER_LIQUID: PackedStringArray = ["water", "soil"]
const WATER_SOLID: PackedStringArray = ["snow"]
const WATER_VAPOUR: PackedStringArray = ["moisture"]
const ORGANIC: PackedStringArray = ["fuel", "biomass", "detritus", "fungus"]
const CARBONATE: PackedStringArray = ["carbonate"]
const SILICA: PackedStringArray = ["silica"]

## Every channel this model reads, in one list, so a caller can ask for exactly the right set (e.g. as a
## `request_probe` leg list) without restating it.
static func channels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for g in [MATRIX, SILICATE, CARBONATE, SILICA, WATER_LIQUID, WATER_SOLID, WATER_VAPOUR, ORGANIC]:
		for name in g:
			out.append(name)
	return out


## The mix, from volume fractions already grouped by substance. This is the exact body of
## kernels3d/rc_shared.glsli `rc_of()`; if you are changing one, change the other in the same commit.
static func mix(f_silicate: float, f_carbonate: float, f_silica: float, f_water: float,
		f_snow: float, f_vapour: float, f_organic: float) -> float:
	var s: float = clampf(f_silicate, 0.0, 1.0)
	var cb: float = clampf(f_carbonate, 0.0, 1.0)
	var si: float = clampf(f_silica, 0.0, 1.0)
	var w: float = clampf(f_water, 0.0, 1.0)
	var sn: float = clampf(f_snow, 0.0, 1.0)
	var v: float = clampf(f_vapour, 0.0, 1.0)
	var o: float = clampf(f_organic, 0.0, 1.0)
	# Air fills whatever is left. It cannot go negative: the fractions are each clamped to [0,1] and their
	# sum is allowed to exceed 1 (an over-full cell is a substrate defect, not this function's to hide), in
	# which case the cell is simply all condensed matter and holds no air.
	var air: float = maxf(0.0, 1.0 - s - cb - si - w - sn - v - o)
	return LAPhysical.VOL_HEAT_CAP_AIR_J_M3K * air \
		+ LAPhysical.VOL_HEAT_CAP_ROCK_J_M3K * s \
		+ LAPhysical.VOL_HEAT_CAP_CARBONATE_J_M3K * cb \
		+ LAPhysical.VOL_HEAT_CAP_SILICA_J_M3K * si \
		+ LAPhysical.VOL_HEAT_CAP_WATER_J_M3K * w \
		+ LAPhysical.VOL_HEAT_CAP_SNOW_J_M3K * sn \
		+ LAPhysical.VOL_HEAT_CAP_VAPOUR_J_M3K * v \
		+ LAPhysical.VOL_HEAT_CAP_ORGANIC_J_M3K * o


## One cell, from a dictionary of channel name -> PackedFloat32Array. A channel that is absent, or whose
## array is the wrong length, contributes ZERO — which is the honest answer for "this instrument did not
## sample that channel", and is why callers that care publish a liveness map beside their result.
static func cell(ch: Dictionary, c: int) -> float:
	var phi: float = 0.0
	var pa = ch.get("porosity")
	if pa is PackedFloat32Array and c < pa.size():
		phi = clampf(pa[c], 0.0, 1.0)
	var silicate: float = _sum(ch, MATRIX, c) * (1.0 - phi) + _sum(ch, SILICATE, c)
	return mix(silicate, _sum(ch, CARBONATE, c), _sum(ch, SILICA, c),
		_sum(ch, WATER_LIQUID, c), _sum(ch, WATER_SOLID, c), _sum(ch, WATER_VAPOUR, c),
		_sum(ch, ORGANIC, c))


## The whole field at once, as float64. Prefer this to calling `cell()` in a loop: it hoists the dictionary
## lookups and the length checks out of the per-cell path, which matters at ~1e5 cells sampled every report.
##
## FLOAT64 IS DELIBERATE. Callers difference these arrays between samples, so the storage precision sets the
## noise floor of whatever they are measuring. Held as float32, rc (~2.4e6, ulp ~0.25) put a spurious
## ~5e8 J/checkpoint on LAMaterialFieldEnergyProbe3D's readings — enough to make nine passes that write no
## temperature at all appear to be moving heat.
static func field(ch: Dictionary, cell_count: int) -> PackedFloat64Array:
	var groups: Array = [SILICATE, CARBONATE, SILICA, WATER_LIQUID, WATER_SOLID, WATER_VAPOUR, ORGANIC]
	var matrix: Array = []
	for name in MATRIX:
		var ma = ch.get(name)
		if ma is PackedFloat32Array and ma.size() >= cell_count:
			matrix.append(ma)
	var phi_a = ch.get("porosity")
	var have_phi: bool = phi_a is PackedFloat32Array and phi_a.size() >= cell_count
	var live: Array = []
	for g in groups:
		var arrays: Array = []
		for name in g:
			var a = ch.get(name)
			if a is PackedFloat32Array and a.size() >= cell_count:
				arrays.append(a)
		live.append(arrays)
	var out: PackedFloat64Array = PackedFloat64Array()
	out.resize(cell_count)
	for c in cell_count:
		var f: Array = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
		for gi in 7:
			var acc: float = 0.0
			for a in live[gi]:
				acc += a[c]
			f[gi] = acc
		# The matrix channel converts from saturation to mineral volume fraction before it joins the mix.
		var phi: float = clampf(phi_a[c], 0.0, 1.0) if have_phi else 0.0
		var m: float = 0.0
		for a in matrix:
			m += a[c]
		out[c] = mix(m * (1.0 - phi) + f[0], f[1], f[2], f[3], f[4], f[5], f[6])
	return out


## The field's total heat capacity BY SUBSTANCE, J/m3K summed over cells (multiply by the cell volume for
## J/K). This lives here rather than in the ledger because it is the same model read a different way: a
## carrier added to the mix above appears in these legs automatically, where a hand-written breakdown in the
## ledger silently kept reporting four legs while the model counted fifteen channels.
static func legs(ch: Dictionary, cell_count: int) -> Dictionary:
	var phi_a = ch.get("porosity")
	var have_phi: bool = phi_a is PackedFloat32Array and phi_a.size() >= cell_count
	var groups: Array = [["silicate", SILICATE, LAPhysical.VOL_HEAT_CAP_ROCK_J_M3K],
		["carbonate", CARBONATE, LAPhysical.VOL_HEAT_CAP_CARBONATE_J_M3K],
		["silica", SILICA, LAPhysical.VOL_HEAT_CAP_SILICA_J_M3K],
		["water", WATER_LIQUID, LAPhysical.VOL_HEAT_CAP_WATER_J_M3K],
		["snow", WATER_SOLID, LAPhysical.VOL_HEAT_CAP_SNOW_J_M3K],
		["vapour", WATER_VAPOUR, LAPhysical.VOL_HEAT_CAP_VAPOUR_J_M3K],
		["organic", ORGANIC, LAPhysical.VOL_HEAT_CAP_ORGANIC_J_M3K]]
	var out: Dictionary = {}
	var occupied: float = 0.0
	# The matrix channel first, converted from saturation to mineral volume fraction, then folded into the
	# silicate leg it belongs to — one substance, one leg.
	var matrix_acc: float = 0.0
	for name in MATRIX:
		var ma = ch.get(name)
		if ma is PackedFloat32Array and ma.size() >= cell_count:
			for c in cell_count:
				var phi: float = clampf(phi_a[c], 0.0, 1.0) if have_phi else 0.0
				matrix_acc += clampf(ma[c], 0.0, 1.0) * (1.0 - phi)
	for g in groups:
		var acc: float = 0.0
		for name in g[1]:
			var a = ch.get(name)
			if a is PackedFloat32Array and a.size() >= cell_count:
				for c in cell_count:
					acc += clampf(a[c], 0.0, 1.0)
		if g[0] == "silicate":
			acc += matrix_acc
		out[g[0]] = acc * g[2]
		occupied += acc
	# Air is the remainder of the grid, floored at zero per cell the same way `mix` floors it.
	out["air"] = maxf(0.0, float(cell_count) - occupied) * LAPhysical.VOL_HEAT_CAP_AIR_J_M3K
	return out


## The capacity of a cell that is entirely one substance. For boundary conditions that are a material by
## definition rather than a mixture — the geotherm's rock floor is the only caller today.
static func pure_rock() -> float:
	return mix(1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)


## Which of this model's channels the caller actually supplied. Publish it beside any number derived from
## `field()` or `cell()`: an absent channel reads as zero, and a reader cannot otherwise tell "there is no
## groundwater here" from "nobody sampled the groundwater".
static func live_map(ch: Dictionary, cell_count: int) -> Dictionary:
	var out: Dictionary = {}
	for name in channels():
		var a = ch.get(name)
		out[name] = a is PackedFloat32Array and a.size() >= cell_count
	var phi = ch.get("porosity")
	out["porosity"] = phi is PackedFloat32Array and phi.size() >= cell_count
	return out


static func _sum(ch: Dictionary, group: PackedStringArray, c: int) -> float:
	var acc: float = 0.0
	for name in group:
		var a = ch.get(name)
		if a is PackedFloat32Array and c < a.size():
			acc += a[c]
	return acc
