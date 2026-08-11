class_name LAHeatCapacity
extends RefCounted


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


## The per-cell volumetric heat capacity of the mix, J/m3K, one entry per cell.
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
