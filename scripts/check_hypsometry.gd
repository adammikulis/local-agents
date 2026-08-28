extends SceneTree

# THE SEEDED BODY'S AREA-BY-ELEVATION AGAINST EARTH'S OWN. Builds the planet's SDF, solves the surface
# radius along an even sweep of directions, and reads that histogram against LAPhysical's hypsographic
# curve. The sweep is a different lattice from the one the generator measured its cascade over, so this
# is an independent reading and not the construction checking itself.

const SAMPLES: int = 4096
## Elevation a quantile may miss the declared curve by, metres.
const TOLERANCE_M: float = 600.0
## Land fraction may miss the declared one by this.
const LAND_TOLERANCE: float = 0.02
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
	svc.build_planet(root, {"radius": r, "seed": 1337, "caves_enabled": true})
	var sea: float = svc.sea_radius()
	var hs: Array[float] = []
	for d: Vector3 in LAPlanetShape.directions(SAMPLES):
		var sr: float = svc.surface_radius(d)
		if not is_nan(sr):
			hs.append(sr - sea)
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
	var land: float = 0.0
	for h: float in hs:
		if h > 0.0:
			land += 1.0
	land /= float(n)
	if absf(land - LAPhysical.HYPSOMETRY_LAND_AREA_FRACTION) > LAND_TOLERANCE:
		bad += 1
		print("HYPSOMETRY_VIOLATION land_fraction=%.4f declared=%.4f" % [
			land, LAPhysical.HYPSOMETRY_LAND_AREA_FRACTION])
	compared += 1
	if hs[0] < LAPhysical.HYPSOMETRY_DEEPEST_M:
		bad += 1
		print("HYPSOMETRY_VIOLATION deepest=%.0f declared=%.0f" % [
			hs[0], LAPhysical.HYPSOMETRY_DEEPEST_M])
	if hs[n - 1] > LAPhysical.HYPSOMETRY_HIGHEST_M:
		bad += 1
		print("HYPSOMETRY_VIOLATION highest=%.0f declared=%.0f" % [
			hs[n - 1], LAPhysical.HYPSOMETRY_HIGHEST_M])
	compared += 2
	print('HYPSOMETRY={"compared":%d,"violations":%d,"land_fraction":%.4f,"deepest":%.0f,"highest":%.0f}'
		% [compared, bad, land, hs[0], hs[n - 1]])
	quit(0)
