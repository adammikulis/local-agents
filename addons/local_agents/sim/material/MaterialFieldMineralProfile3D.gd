class_name LAMaterialFieldMineralProfile3D
extends RefCounted

## LAMaterialFieldMineralProfile3D: WHERE the planet's loose mineral is, by elevation — not how much of it
## there is. Diagnostic only, created by LAMaterialFieldSphereStep3D and only when `LA_MINERAL_PROFILE` is in
## the environment, because a sample is a full-grid CPU walk.
##
## WHY A PROFILE AND NOT A TOTAL. `sediment_total` and `susp_total` are scalars, and a scalar cannot answer
## the only question sediment transport raises: does mineral MOVE DOWNHILL? A river that scours its bed and
## drops the load back into the same cell publishes exactly the same totals as one that carries it to a basin
## and builds a delta. The two are the difference between a planet with a landscape history and one without,
## and no aggregate in SIM_REPORT can tell them apart. This measures the SHAPE of the distribution instead.
##
## THE METHOD — first split the pools, then measure only the one that can move.
##
## 0. THE SPLIT. Loose mineral sits in three places that behave nothing alike: BURIED inside solid rock,
##    DEEP in enclosed cavities below the local bed, and on the SURFACE above it. Only the last is reachable
##    by water. Mixing them makes the aggregate move for reasons unrelated to transport, which is exactly what
##    the first version of this probe did. `buried_loose` and `deep_loose` are reported as bare totals; every
##    other statistic here is over the surface pool alone.
##
## 1. BED TERCILES, the structural one. Every surface column has a bed top: the outermost solid shell. Bin the
##    columns into low / middle / high thirds BY THAT, cutting the terciles from the terrain itself so each
##    bin holds the same number of columns and the bins do not move with the mineral. Then sum the surface
##    mineral standing in each bin. A distribution shifting from `hi` to `lo` is downhill transport, and
##    `lo_over_hi` is the single number that says so.
##
## 2. MEAN BED ELEVATION, the direct one. `surf_mean_bed` is the bed elevation the surface mineral is lying
##    on, mass-weighted. `bed_mean` is the same average over the ground itself. `surf_bed_offset` is the
##    difference: how far below the planet's average ground the loose mineral has come to rest.
##
## 3. MEAN SHELL and SHELL HISTOGRAM, the fine-grained ones. A cell's radial shell index is its elevation in
##    cells. `surf_mean_shell` is that index mass-weighted; `shell_hist` is the whole distribution, twenty
##    numbers, because a scalar cannot show a shape. `surf_above_bed` is the mean height above the LOCAL bed,
##    which says how thickly the deposit stands independently of where the bed is.
##
## `field_step` is what any two samples must be compared at: these are not steady quantities, and comparing
## them at equal FRAMES compares two different horizons.
##
## NOT USED: `rock_fill`. It would give a sub-cell continuous bed elevation, but its CPU mirror is
## demand-gated (MaterialSphereGPU3D.SITUATIONAL_CHANNELS) and only refreshes while something has armed it,
## so a profile built on it would be silently stale. The solid mask and the two loose phases are read every
## slow drain.
## (Explicit types only, no ':=' inferred typing.)

## Field steps between printed profiles. A sample walks every cell once, so this is not free.
const SAMPLE_EVERY: int = 100

## A cell counts as actively eroding when it is carrying a real suspended load. Well above fp noise and well
## below a single scour event (erosion_pickup_sphere3d.MAX_SCOUR is 0.08), so it counts cells with a load in
## transit rather than cells with a rounding error.
const SUSP_ACTIVE: float = 0.001


## How many OPEN cells are currently carrying suspended mineral — the honest `erosion_cells` gauge.
##
## This is static and takes its inputs directly so the field can forward to it without owning a diagnostic
## instance, and so it costs one walk of two packed arrays rather than a profile sample.
##
## (Added 2026-08-03. `LAMaterialField3D.erosion_cell_count()` was `return 0` — a hardcoded zero published in
## every SIM_REPORT as `erosion_cells`. It read "no erosion anywhere" for the entire period in which erosion
## genuinely could not move anything, and it would have read exactly the same if erosion had been working
## perfectly. A gauge that cannot distinguish those two states is not a weak gauge, it is a false one.)
static func suspended_cell_count(susp: PackedFloat32Array, solid: PackedByteArray) -> int:
	var n: int = susp.size()
	if n == 0 or solid.size() != n:
		return 0
	var count: int = 0
	for c in n:
		if solid[c] == 0 and susp[c] > SUSP_ACTIVE:
			count += 1
	return count

var _f = null                    # back-reference to the owning LAMaterialField3D
var _gate: int = 0
# FROZEN BINS. The low/mid/high tercile a column belongs to is decided ONCE, on the first sample, and reused
# for every sample after it. Re-cutting the terciles each time would compare two different sets of columns and
# could hide the very thing this measures: if the highlands erode down and the basins fill up, a re-cut bin
# boundary moves with them and the shift cancels out. Frozen bins make it a PAIRED measurement — the same
# columns, tracked — so `bed_hi_mean` falling while `bed_lo_mean` rises is landscape evolution, and `relief`
# is the number that says so.
var _bin: PackedByteArray = PackedByteArray()   # per column: 0 = low tercile, 1 = middle, 2 = high
var _bin_ready: bool = false


func setup(field) -> void:
	_f = field


## Called once per field step by LAMaterialFieldSphereStep3D. Samples on the SAMPLE_EVERY cadence.
func post_step() -> void:
	_gate += 1
	if _gate < SAMPLE_EVERY:
		return
	_gate = 0
	var p: Dictionary = sample()
	if p.is_empty():
		return
	print("MINERAL_PROFILE=", JSON.stringify(p))


## One elevation profile of the mobile mineral phases. Empty on the box path or before the grid exists.
func sample() -> Dictionary:
	if _f == null or _f._sphere == null:
		return {}
	var grid: RefCounted = _f._sphere
	var depth: int = int(grid.depth)
	var surf: int = int(grid.surf_count)
	var cc: int = _f._cell_count
	if depth <= 0 or surf <= 0 or cc != surf * depth:
		return {}
	if _f._solid.size() != cc or _f._sediment.size() != cc or _f._susp.size() != cc:
		return {}

	# --- one walk: split the loose mineral into the three pools that behave completely differently ---------
	# THIS SPLIT IS THE WHOLE MEASUREMENT. Only a fraction of this planet's loose mineral can move at all, and
	# averaging the three pools together hides the one that can:
	#   BURIED  — inside a SOLID cell, swallowed by bedrock that grew over it. No CA steps a solid cell.
	#   DEEP    — in an OPEN cell at or below its column's bed top: an enclosed cavity in the crust (this run
	#             reports ~2300 of them). Open, but no surface water reaches it, so nothing carries it either.
	#   SURFACE — in an OPEN cell ABOVE its column's bed top. This is the pool rivers, lakes and the sea touch,
	#             and the only one erosion transport can act on.
	# Measured before the split: the combined mean shell read 2.4-2.7 while the bed top averaged 8.8, i.e. the
	# number was describing the deep interior and would have moved for reasons that have nothing to do with
	# transport. Every statistic below is over the SURFACE pool; the other two are reported as bare totals so
	# nothing is hidden.
	var bed: PackedInt32Array = PackedInt32Array()
	bed.resize(surf)
	var col_surf: PackedFloat32Array = PackedFloat32Array()
	col_surf.resize(surf)
	var col_susp: PackedFloat32Array = PackedFloat32Array()
	col_susp.resize(surf)
	var buried: float = 0.0
	var deep: float = 0.0
	var sed_mass: float = 0.0
	var sed_shell: float = 0.0
	var susp_mass: float = 0.0
	var susp_shell: float = 0.0
	var above_bed: float = 0.0                                # mass-weighted height above the LOCAL bed
	var hist: PackedFloat32Array = PackedFloat32Array()        # surface pool by radial shell
	hist.resize(depth)
	for s in surf:
		var base: int = s * depth
		var top: int = -1
		for r in depth:
			if _f._solid[base + r] != 0:
				top = r
		bed[s] = top
		var m_surf: float = 0.0
		var m_susp: float = 0.0
		for r in depth:
			var c: int = base + r
			var sd: float = _f._sediment[c]
			var sp: float = _f._susp[c]
			var m: float = sd + sp
			if _f._solid[c] != 0:
				buried += m
				continue
			if r <= top:
				deep += m
				continue
			sed_mass += sd
			sed_shell += sd * float(r)
			susp_mass += sp
			susp_shell += sp * float(r)
			above_bed += m * float(r - top)
			hist[r] += m
			m_surf += m
			m_susp += sp
		col_surf[s] = m_surf
		col_susp[s] = m_susp

	# --- tercile bins, cut from the TERRAIN on the FIRST sample and then FROZEN (see _bin) ---------------
	var land: PackedInt32Array = PackedInt32Array()
	for s in surf:
		if bed[s] >= 0:
			land.append(bed[s])
	if land.size() < 3:
		return {}
	land.sort()
	var cut_lo: int = land[int(land.size() / 3)]
	var cut_hi: int = land[int(2 * land.size() / 3)]
	if not _bin_ready or _bin.size() != surf:
		_bin.resize(surf)
		for s in surf:
			var b0: int = bed[s]
			_bin[s] = 0 if b0 < cut_lo else (1 if b0 < cut_hi else 2)
		_bin_ready = true

	var bed_sum: float = 0.0
	var loose_lo: float = 0.0
	var loose_mid: float = 0.0
	var loose_hi: float = 0.0
	var loose_total: float = 0.0
	var loose_elev: float = 0.0
	var susp_total: float = 0.0
	var susp_elev: float = 0.0
	var bed_lo_sum: float = 0.0
	var bed_hi_sum: float = 0.0
	var n_lo: int = 0
	var n_hi: int = 0
	for s in surf:
		var b: int = bed[s]
		if b < 0:
			continue
		bed_sum += float(b)
		var m: float = col_surf[s]
		loose_total += m
		loose_elev += m * float(b)
		susp_total += col_susp[s]
		susp_elev += col_susp[s] * float(b)
		var k: int = _bin[s]
		if k == 0:
			loose_lo += m
			bed_lo_sum += float(b)
			n_lo += 1
		elif k == 1:
			loose_mid += m
		else:
			loose_hi += m
			bed_hi_sum += float(b)
			n_hi += 1

	var n_land: int = land.size()
	var bed_mean: float = bed_sum / float(n_land)
	var bed_lo_mean: float = bed_lo_sum / maxf(float(n_lo), 1.0)
	var bed_hi_mean: float = bed_hi_sum / maxf(float(n_hi), 1.0)
	var mobile_mass: float = sed_mass + susp_mass
	var shells: Array = []
	for r in depth:
		shells.append(snappedf(hist[r], 0.01))
	return {
		"field_step": (_f._gpu._step_index if _f._gpu != null else 0),
		"land_columns": n_land,
		"bed_mean": snappedf(bed_mean, 0.001),
		"bed_cut_lo": cut_lo,
		"bed_cut_hi": cut_hi,
		# THE LANDSCAPE ITSELF, over the frozen tercile bins. If mineral genuinely moves downhill, the high
		# third of the columns loses ground and the low third gains it, so `relief` shrinks. This is the goal
		# the loose-mineral statistics below are only a leading indicator of.
		"bed_lo_mean": snappedf(bed_lo_mean, 0.001),
		"bed_hi_mean": snappedf(bed_hi_mean, 0.001),
		"relief": snappedf(bed_hi_mean - bed_lo_mean, 0.001),
		# The two immobile pools, reported so they are never silently averaged into the mobile one.
		"buried_loose": snappedf(buried, 0.001),
		"deep_loose": snappedf(deep, 0.001),
		# --- everything below is the SURFACE pool only ---
		"surf_loose": snappedf(loose_total, 0.001),
		"surf_susp": snappedf(susp_total, 0.001),
		# Mass-weighted mean radial shell — elevation at cell resolution.
		"surf_mean_shell": snappedf((sed_shell + susp_shell) / maxf(mobile_mass, 1.0e-9), 0.001),
		"sed_mean_shell": snappedf(sed_shell / maxf(sed_mass, 1.0e-9), 0.001),
		"susp_mean_shell": snappedf(susp_shell / maxf(susp_mass, 1.0e-9), 0.001),
		# Height above the LOCAL bed: how thick the deposit stands, independent of where the bed is.
		"surf_above_bed": snappedf(above_bed / maxf(mobile_mass, 1.0e-9), 0.001),
		# Mass-weighted BED elevation: which ground the loose mineral is lying on. Below `bed_mean` means it
		# sits on lower ground than the planet's average, i.e. it has moved downhill from where it was made.
		"surf_mean_bed": snappedf(loose_elev / maxf(loose_total, 1.0e-9), 0.001),
		"surf_bed_offset": snappedf(loose_elev / maxf(loose_total, 1.0e-9) - bed_mean, 0.001),
		"susp_mean_bed": snappedf(susp_elev / maxf(susp_total, 1.0e-9), 0.001),
		"surf_lo": snappedf(loose_lo, 0.001),
		"surf_mid": snappedf(loose_mid, 0.001),
		"surf_hi": snappedf(loose_hi, 0.001),
		"lo_over_hi": snappedf(loose_lo / maxf(loose_hi, 1.0e-9), 0.0001),
		"shell_hist": shells,
	}
