extends SceneTree

# THE SEEDED BODY'S AREA-BY-ELEVATION AGAINST EARTH'S OWN, and the water standing on it against the level
# that inventory reaches on that curve at this body's radius. The sweep is a different lattice from the one
# the generator measured its cascade over, and different again from the one LAWaterFill floods, so neither
# reading is the construction checking itself. The land fraction is REPORTED, never held to Earth's: it is
# a joint fact about this body's radius, its water inventory and its relief, and only the last is Earth's.

const SAMPLES: int = 4096
## Elevation a quantile may miss the declared curve by, metres.
const TOLERANCE_M: float = 600.0
## Metres the fill's water surface may miss the level that inventory reaches on the curve.
const LEVEL_TOLERANCE_M: float = 600.0
## Quantiles compared. The extreme tails hold too few samples to state a quantile, so they are held by
## the declared extremes instead.
const Q_LO: float = 0.02
const Q_HI: float = 0.98
const Q_STEPS: int = 25


func _init() -> void:
	var svc: RefCounted = load("res://addons/local_agents/sim/terrain/VoxelTerrainService.gd").new()
	var r: float = LABodySeeds.seed_radius_m("planet")
	if not (r > 0.0):
		printerr("HYPSOMETRY: the body record states no mass, so it has no radius to shape.")
		quit(2)
		return
	var root: Node3D = Node3D.new()
	get_root().add_child(root)
	svc.build_planet(root, {"radius": r, "seed": 1337})
	var hs: Array[float] = []
	var dry: int = 0
	var deepest_r: float = INF
	var level: float = NAN
	for d: Vector3 in LAPlanetShape.directions(SAMPLES):
		var sr: float = svc.surface_radius(d)
		if is_nan(sr):
			continue
		hs.append(sr - r)
		var w: float = svc.water_radius(d)
		if is_nan(w) or sr >= w:
			dry += 1
			continue
		# The surface of the water over the DEEPEST crust the sweep found: the largest body's own level.
		if sr < deepest_r:
			deepest_r = sr
			level = w - r
	hs.sort()
	var n: int = hs.size()
	if n < Q_STEPS:
		printerr("HYPSOMETRY: the sweep solved %d surface radii, so nothing was compared." % n)
		quit(2)
		return

	var bad: int = 0
	var compared: int = 0
	for k in range(Q_STEPS):
		var q: float = Q_LO + (Q_HI - Q_LO) * float(k) / float(Q_STEPS - 1)
		var got: float = hs[clampi(int(round(q * float(n - 1))), 0, n - 1)]
		var want: float = LAPlanetShape.elevation_at_area(q)
		compared += 1
		if absf(got - want) > TOLERANCE_M:
			bad += 1
			print("HYPSOMETRY_VIOLATION q=%.3f elevation=%.0f declared=%.0f" % [q, got, want])
	var land: float = float(dry) / float(n)
	# THE FILL AGAINST THE CURVE: a priority flood over a lattice on one side, an integral on the other.
	var want_level: float = _curve_level(r)
	if is_nan(level) or is_nan(want_level):
		printerr("HYPSOMETRY: the fill left no water surface, so its level cannot be read against the curve.")
		quit(2)
		return
	if absf(level - want_level) > LEVEL_TOLERANCE_M:
		bad += 1
		print("HYPSOMETRY_VIOLATION water_level=%.0f curve=%.0f" % [level, want_level])
	compared += 1
	var mean: float = LAPlanetShape.hypsometric_mean_m()
	if hs[0] < LAPhysical.HYPSOMETRY_DEEPEST_M - mean:
		bad += 1
		print("HYPSOMETRY_VIOLATION deepest=%.0f declared=%.0f" % [
			hs[0], LAPhysical.HYPSOMETRY_DEEPEST_M - mean])
	if hs[n - 1] > LAPhysical.HYPSOMETRY_HIGHEST_M - mean:
		bad += 1
		print("HYPSOMETRY_VIOLATION highest=%.0f declared=%.0f" % [
			hs[n - 1], LAPhysical.HYPSOMETRY_HIGHEST_M - mean])
	compared += 2
	print('HYPSOMETRY={"compared":%d,"violations":%d,"land_fraction":%.4f,"water_level":%.0f,"curve_level":%.0f,"deepest":%.0f,"highest":%.0f}'
		% [compared, bad, land, level, want_level, hs[0], hs[n - 1]])
	quit(0)


## Elevation over the mean crust radius at which the body's declared surface water covers the curve. The
## curve is piecewise linear in cumulative area, so each segment's wet volume is exact.
func _curve_level(r_body: float) -> float:
	var body: Dictionary = LABodySeeds.of("planet")
	var rho_w: float = float(LASubstances.table().get("h2o", {}).get("density", 0.0))
	if rho_w <= 0.0 or not body.has("hydrosphere_kg") or not body.has("groundwater_kg"):
		return NAN
	var want: float = (float(body["hydrosphere_kg"]) - float(body["groundwater_kg"])) / rho_w
	var a: Array[float] = LAPhysical.HYPSOMETRY_AREA_BELOW
	var e: Array[float] = LAPhysical.HYPSOMETRY_ELEVATION_M
	var mean: float = LAPlanetShape.hypsometric_mean_m()
	var lo: float = e[0] - mean
	var hi: float = e[e.size() - 1] - mean
	for _k in 80:
		var mid: float = 0.5 * (lo + hi)
		if 4.0 * PI * r_body * r_body * _wet_column(mid, a, e, mean) < want:
			lo = mid
		else:
			hi = mid
	return 0.5 * (lo + hi)


## Water column per unit surface area, metres, held under `level` by the curve.
func _wet_column(level: float, a: Array[float], e: Array[float], mean: float) -> float:
	var acc: float = 0.0
	for i in range(1, a.size()):
		var d0: float = maxf(level - (e[i - 1] - mean), 0.0)
		var d1: float = maxf(level - (e[i] - mean), 0.0)
		var span: float = a[i] - a[i - 1]
		if d0 > 0.0 and d1 > 0.0:
			acc += 0.5 * (d0 + d1) * span
		elif d0 > 0.0 or d1 > 0.0:
			var rise: float = absf(e[i] - e[i - 1])
			var wet: float = span * maxf(d0, d1) / rise if rise > 0.0 else 0.0
			acc += 0.5 * maxf(d0, d1) * wet
	return acc
