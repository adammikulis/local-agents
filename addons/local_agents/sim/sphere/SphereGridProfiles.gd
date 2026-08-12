class_name LASphereGridProfiles
extends RefCounted

## Radial shell-thickness profiles for `LASphereGrid.build`. A profile decides the planet's vertical
## resolution, so it is a declared modelling choice: see docs/MODEL_PARAMETERS.md.

const ENV_VAR: String = "LA_SHELL_PROFILE"
const UNIFORM: String = "uniform"
const SURFACE_FOCUS: String = "surface_focus"


## The profile named by `LA_SHELL_PROFILE`, or an empty table — uniform — when it is unset.
static func from_env(depth: int, mean_dr: float, surf_index: int) -> PackedFloat32Array:
	var name: String = OS.get_environment(ENV_VAR)
	if name == SURFACE_FOCUS:
		return surface_focus(depth, mean_dr, surf_index)
	return PackedFloat32Array()


## Thinnest shell the grid needs, model units: the aquifer's circulation depth over the shells modelling it.
static func aquifer_shell_units() -> float:
	var metres: float = LAPhysical.GROUNDWATER_CIRCULATION_M / float(LAMaterialFieldRegolith3D.REGOLITH_CELLS)
	return metres


## A flat band of `REGOLITH_CELLS` shells at the aquifer thickness, ending at the surface shell, growing
## geometrically away from that band both ways. The growth ratio is solved for, so the span is unchanged.
static func surface_focus(depth: int, mean_dr: float, surf_index: int = -1) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	if depth <= 0 or mean_dr <= 0.0:
		return out
	var focus: int = surf_index if surf_index >= 0 and surf_index < depth else depth / 2
	var span: float = float(depth) * mean_dr
	var dr_min: float = aquifer_shell_units()
	if dr_min >= mean_dr:
		return out
	var band_lo: int = maxi(0, focus - LAMaterialFieldRegolith3D.REGOLITH_CELLS + 1)
	var growth: float = _solve_growth(depth, band_lo, focus, span, dr_min)
	out.resize(depth)
	var total: float = 0.0
	for r in depth:
		out[r] = dr_min * pow(growth, _band_distance(r, band_lo, focus))
		total += out[r]
	for r in depth:
		out[r] = out[r] * span / total
	return out


## Shells from `r` to the nearest edge of the flat band; 0 inside it.
static func _band_distance(r: int, band_lo: int, band_hi: int) -> float:
	if r < band_lo:
		return float(band_lo - r)
	if r > band_hi:
		return float(r - band_hi)
	return 0.0


## Bisect for the growth ratio whose column spans `span`. 1.0 is the uniform limit, 4.0 overshoots any span.
static func _solve_growth(depth: int, band_lo: int, band_hi: int, span: float, dr_min: float) -> float:
	var lo: float = 1.0
	var hi: float = 4.0
	for _i in 64:
		var mid: float = 0.5 * (lo + hi)
		if _span_at(depth, band_lo, band_hi, dr_min, mid) < span:
			lo = mid
		else:
			hi = mid
	return 0.5 * (lo + hi)


static func _extreme(dr: PackedFloat32Array, want_max: bool) -> float:
	if dr.is_empty():
		return 0.0
	var best: float = dr[0]
	for v in dr:
		best = maxf(best, v) if want_max else minf(best, v)
	return best


static func _span_at(depth: int, band_lo: int, band_hi: int, dr_min: float, growth: float) -> float:
	var total: float = 0.0
	for r in depth:
		total += dr_min * pow(growth, _band_distance(r, band_lo, band_hi))
	return total


## What a profile buys: metres at the surface shell, cells within a km of it, whether the aquifer fits.
static func describe(table: PackedFloat32Array, depth: int, mean_dr: float, surf_index: int) -> Dictionary:
	var dr: PackedFloat32Array = table
	if dr.size() != depth:
		dr = PackedFloat32Array()
		dr.resize(depth)
		dr.fill(mean_dr)
	var focus: int = clampi(surf_index, 0, depth - 1)
	var reg: int = LAMaterialFieldRegolith3D.REGOLITH_CELLS
	var reg_m: float = 0.0
	for k in reg:
		var r: int = focus - k
		if r >= 0:
			reg_m += dr[r]
	var within_km: int = 0
	var walk: float = 0.0
	for r in range(focus, -1, -1):
		walk += dr[r]
		if _mm(walk) > 1000.0:
			break
		within_km += 1
	return {
		"surface_shell_m": _mm(dr[focus]),
		"thinnest_m": _mm(_extreme(dr, false)),
		"thickest_m": _mm(_extreme(dr, true)),
		"cells_within_1km_of_surface": within_km,
		"regolith_band_m": _mm(reg_m),
		"aquifer_resolved": _mm(reg_m) <= LAPhysical.GROUNDWATER_CIRCULATION_M,
	}


## Metres, to the millimetre. The table is float32, so a 2000 m band reads 2000.000006 and loses an exact
## comparison against a round threshold; a millimetre is far below anything this grid resolves.
static func _mm(metres: float) -> float:
	return snappedf(metres, 0.001)
