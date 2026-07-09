extends SceneTree

## Phase A1 spike — prove the NATIVE spherical planet SDF generator compiles and is actually a sphere.
## Run: godot --headless -s addons/local_agents/scenes/simulation/voxel/sphere/spike_planet.gd
## Prints PLANET_REPORT={...}. Gates:
##   compiled           — the voxel graph compiled successfully.
##   is_sphere          — raycasts from many directions all hit the surface near `radius` (±relief), so the
##                        solid is a ball, not a box/heightmap; spread bounded → no directional bias.
##   center_solid       — the SDF is negative (rock) at the core.
##   space_empty        — the SDF is positive (air) well outside the planet.

const Planet = preload("res://addons/local_agents/scenes/simulation/voxel/sphere/SpherePlanetGenerator.gd")


func _initialize() -> void:
	var R: float = 250.0
	var relief: float = 26.0
	var p: RefCounted = Planet.new()
	var gen: VoxelGeneratorGraph = p.build({"radius": R, "relief": relief, "seed": 7})
	var compiled: bool = bool(gen.compile().get("success", false))

	# Raycast the surface from 20 directions; each ray goes from 2R out toward the centre.
	# raycast_sdf_approx returns distance along the ray to the first surface crossing (<0 = miss).
	var dirs: Array[Vector3] = _sample_dirs(20)
	var hit_radii: PackedFloat32Array = PackedFloat32Array()
	var misses: int = 0
	for d: Vector3 in dirs:
		var origin: Vector3 = d * (R * 2.0)
		var end: Vector3 = d * (R * 0.2)        # stop short of centre
		var dist: float = gen.raycast_sdf_approx(origin, end, 0.5)
		if dist < 0.0:
			misses += 1
			continue
		var hit: Vector3 = origin + (end - origin).normalized() * dist
		hit_radii.append(hit.length())

	var rmin: float = 1e9
	var rmax: float = -1e9
	var rsum: float = 0.0
	for r: float in hit_radii:
		rmin = minf(rmin, r)
		rmax = maxf(rmax, r)
		rsum += r
	var rmean: float = rsum / maxf(1.0, float(hit_radii.size()))
	# a real sphere: every hit within relief(+margin) of R, and no misses
	var is_sphere: bool = misses == 0 and hit_radii.size() == dirs.size() \
		and rmin > R - relief - 8.0 and rmax < R + relief + 8.0

	# core solid: sample the ACTUAL SDF at the planet centre via a generated block — must be negative (rock).
	# (raycast_sdf_approx sphere-traces from POSITIVE sdf, so it can't probe from inside the solid.)
	var buf: VoxelBuffer = VoxelBuffer.new()
	buf.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_32_BIT)
	buf.create(16, 16, 16)
	gen.generate_block(buf, Vector3(-8, -8, -8), 0)          # world region [-8,8]³ around the core
	var center_sdf: float = buf.get_voxel_f(8, 8, 8, VoxelBuffer.CHANNEL_SDF)
	var center_solid: bool = center_sdf < 0.0

	# space empty: from far outside pointing further out must miss (no phantom matter in space).
	var space_empty: bool = gen.raycast_sdf_approx(Vector3(R * 3.0, 0, 0), Vector3(R * 6.0, 0, 0), 0.5) < 0.0

	var report: Dictionary = {
		"ok": compiled and is_sphere and center_solid and space_empty,
		"compiled": compiled,
		"is_sphere": is_sphere,
		"center_solid": center_solid,
		"space_empty": space_empty,
		"hits": hit_radii.size(), "misses": misses,
		"r_min": snappedf(rmin, 0.01), "r_mean": snappedf(rmean, 0.01), "r_max": snappedf(rmax, 0.01),
		"radius": R, "relief": relief,
	}
	print("PLANET_REPORT=", JSON.stringify(report))
	quit(0 if report["ok"] else 1)


## N roughly-even directions on the sphere (Fibonacci lattice).
func _sample_dirs(n: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var golden: float = PI * (3.0 - sqrt(5.0))
	for i in n:
		var y: float = 1.0 - (float(i) / float(n - 1)) * 2.0
		var rad: float = sqrt(maxf(0.0, 1.0 - y * y))
		var theta: float = golden * float(i)
		out.append(Vector3(cos(theta) * rad, y, sin(theta) * rad).normalized())
	return out
