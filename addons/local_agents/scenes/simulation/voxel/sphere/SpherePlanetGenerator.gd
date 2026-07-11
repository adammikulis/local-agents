class_name LASpherePlanetGenerator
extends RefCounted

## Builds the NATIVE compiled voxel-graph generator for a spherical planet (Phase A1 terrain crux).
##
## The planet is one SDF built from a solid ball minus a relief field:
##   sdf(p) = (length(p) - radius) - relief(p) + ocean_bias
##   surface radius = radius + relief(p) - ocean_bias   (zero-crossing)
##
## RELIEF is dominated by CELLULAR (Worley/Voronoi) noise, return type CELL_VALUE: each Voronoi cell gets its
## own random elevation, so the planet breaks into DISTINCT continents + islands (the cells) separated by the
## sea, with sharp coastlines along the cell borders — a cell-structured world, not a smooth fBm dome where
## everything sheets radially the same. (CELL_VALUE is the only cellular return type with a well-spread
## distribution here; DISTANCE / DISTANCE_2_SUB come back cramped-negative → an all-ocean planet.) A
## low-amplitude fBm detail layer breaks up each plateau into hills + valleys, so runoff finds channels and
## rivers drain to the coast emergently. (Beaches + eroded coasts are a 0.5 job — see the bake-the-planet task.)
##
## OCEAN_BIAS pushes the whole surface inward so most of the sphere sits BELOW the sea shell — an ocean world
## with continents/islands at the cellular cores, the sea for rivers to reach. Raise ocean_bias / raise
## sea_radius for more water; lower for more land.
##
## Everything runs in the native VoxelGeneratorGraph (compiled, SIMD) — NO per-voxel GDScript (native/Big-O
## mandate). godot_voxel's VoxelLodTerrain gives distance-LOD for free. (Explicit types only — no ':=' .)

# VoxelGraphFunction NODE_* type ids (from this build's ClassDB):
const T_OUTPUT_SDF: int = 4
const T_ADD: int = 5
const T_SUBTRACT: int = 6
const T_MULTIPLY: int = 7
const T_SDF_SPHERE: int = 32
const T_FAST_NOISE_3D: int = 40

# SdfSphere input ports: 0=x 1=y 2=z 3=radius (x/y/z autoconnect to world coords when left unwired).

var _radius: float = 250.0
var _sea_radius: float = 250.0

## Planet solid radius (mean sphere the relief rides on).
func radius() -> float:
	return _radius

## Radius of the spherical sea shell (where the ocean surface sits).
func sea_radius() -> float:
	return _sea_radius


## Build + compile the generator. opts (all optional):
##   radius        — mean planet sphere (world units)
##   sea_radius    — ocean shell radius (default == radius, so the mean surface sits at the coastline)
##   ocean_bias    — inward push of the surface; bigger => more of the planet is ocean (default 34)
##   relief        — cellular (continent) amplitude, world units (default 46)
##   detail_relief — fBm roughness amplitude, world units (default 6)
##   feature_size  — cellular cell size / continent wavelength (default 155)
##   detail_size   — fBm detail wavelength (default 44)
##   jitter        — cellular jitter 0..1 (1 => most organic cells; default 1.0)
##   octaves, seed — fBm/cellular fractal octaves + noise seed
## Returns the compiled VoxelGeneratorGraph (pushes an error + returns a still-usable graph on compile fail).
func build(opts: Dictionary = {}) -> VoxelGeneratorGraph:
	_radius = float(opts.get("radius", 250.0))
	_sea_radius = float(opts.get("sea_radius", _radius))
	var ocean_bias: float = float(opts.get("ocean_bias", 7.0))
	var relief: float = float(opts.get("relief", 46.0))
	var detail_relief: float = float(opts.get("detail_relief", 6.0))
	var feature_size: float = float(opts.get("feature_size", 155.0))
	var detail_size: float = float(opts.get("detail_size", 44.0))
	var jitter: float = clampf(float(opts.get("jitter", 1.0)), 0.0, 1.0)
	var octaves: int = int(opts.get("octaves", 3))
	var seed_val: int = int(opts.get("seed", 1337))
	# BASINS: a medium-wavelength simplex layer whose hollows become closed depressions on the otherwise-flat
	# cellular plateaus — the endorheic bowls where springs/rain/runoff POOL into standing lakes (the cellular
	# CELL_VALUE relief is flat-topped, so without this land drains monotonically to the sea and nothing pools).
	var basin_relief: float = float(opts.get("basin_relief", 0.0))
	var basin_size: float = float(opts.get("basin_size", 130.0))

	# CONTINENTS: cellular F2-F1 — high at cell cores, ~0 along the borders (the valley network). Fractal-FBM
	# layered so continents carry sub-cells (bays, sub-basins). This is the drainage-shaping field.
	var cont: ZN_FastNoiseLite = ZN_FastNoiseLite.new()
	cont.noise_type = ZN_FastNoiseLite.TYPE_CELLULAR
	cont.seed = seed_val
	cont.period = maxf(1.0, feature_size)
	cont.cellular_distance_function = ZN_FastNoiseLite.CELLULAR_DISTANCE_EUCLIDEAN
	cont.cellular_return_type = ZN_FastNoiseLite.CELLULAR_RETURN_CELL_VALUE
	cont.cellular_jitter = jitter
	cont.fractal_type = ZN_FastNoiseLite.FRACTAL_FBM
	cont.fractal_octaves = maxi(1, octaves)
	cont.fractal_lacunarity = 2.0
	cont.fractal_gain = 0.5

	# DETAIL: low-amplitude simplex fBm so hillsides have texture (not glass) without drowning the cells.
	var detail: ZN_FastNoiseLite = ZN_FastNoiseLite.new()
	detail.noise_type = ZN_FastNoiseLite.TYPE_OPEN_SIMPLEX_2S
	detail.seed = seed_val + 7
	detail.period = maxf(1.0, detail_size)
	detail.fractal_type = ZN_FastNoiseLite.FRACTAL_FBM
	detail.fractal_octaves = 4
	detail.fractal_lacunarity = 2.0
	detail.fractal_gain = 0.5

	# BASINS: medium-wavelength simplex fBm added to the relief; its ±amplitude undulation carves hollows into
	# the flat plateaus (local minima the water CA fills = lakes) and raises low hills between them.
	var basin: ZN_FastNoiseLite = ZN_FastNoiseLite.new()
	basin.noise_type = ZN_FastNoiseLite.TYPE_OPEN_SIMPLEX_2S
	basin.seed = seed_val + 13
	basin.period = maxf(1.0, basin_size)
	basin.fractal_type = ZN_FastNoiseLite.FRACTAL_FBM
	basin.fractal_octaves = 3
	basin.fractal_lacunarity = 2.0
	basin.fractal_gain = 0.5

	var gen: VoxelGeneratorGraph = VoxelGeneratorGraph.new()
	var fn: VoxelGraphFunction = gen.get_main_function()
	fn.clear()

	# sphere: length(p) - radius
	var sphere: int = fn.create_node(T_SDF_SPHERE, Vector2(0, 0), 0)
	fn.set_node_default_input(sphere, 3, _radius)

	# continent relief = cellular * relief
	var cont_noise: int = fn.create_node(T_FAST_NOISE_3D, Vector2(0, 200), 0)
	fn.set_node_param_by_name(cont_noise, "noise", cont)
	var cont_mul: int = fn.create_node(T_MULTIPLY, Vector2(200, 200), 0)
	fn.add_connection(cont_noise, 0, cont_mul, 0)
	fn.set_node_default_input(cont_mul, 1, relief)

	# detail relief = fbm * detail_relief
	var det_noise: int = fn.create_node(T_FAST_NOISE_3D, Vector2(0, 360), 0)
	fn.set_node_param_by_name(det_noise, "noise", detail)
	var det_mul: int = fn.create_node(T_MULTIPLY, Vector2(200, 360), 0)
	fn.add_connection(det_noise, 0, det_mul, 0)
	fn.set_node_default_input(det_mul, 1, detail_relief)

	# basin relief = fbm * basin_relief  (±amplitude → hollows/hills on the plateaus)
	var basin_noise: int = fn.create_node(T_FAST_NOISE_3D, Vector2(0, 500), 0)
	fn.set_node_param_by_name(basin_noise, "noise", basin)
	var basin_mul: int = fn.create_node(T_MULTIPLY, Vector2(200, 500), 0)
	fn.add_connection(basin_noise, 0, basin_mul, 0)
	fn.set_node_default_input(basin_mul, 1, basin_relief)

	# relief = continent + detail
	var relief_sum: int = fn.create_node(T_ADD, Vector2(400, 280), 0)
	fn.add_connection(cont_mul, 0, relief_sum, 0)
	fn.add_connection(det_mul, 0, relief_sum, 1)

	# relief += basin  (undulate the plateaus so closed depressions exist for water to pool)
	var relief_sum2: int = fn.create_node(T_ADD, Vector2(500, 400), 0)
	fn.add_connection(relief_sum, 0, relief_sum2, 0)
	fn.add_connection(basin_mul, 0, relief_sum2, 1)

	# core = sphere - relief  (raise surface outward where relief is high)
	var core: int = fn.create_node(T_SUBTRACT, Vector2(600, 140), 0)
	fn.add_connection(sphere, 0, core, 0)
	fn.add_connection(relief_sum2, 0, core, 1)

	# biased = core + ocean_bias  (push the whole surface inward => most of the sphere is ocean)
	var biased: int = fn.create_node(T_ADD, Vector2(800, 140), 0)
	fn.add_connection(core, 0, biased, 0)
	fn.set_node_default_input(biased, 1, ocean_bias)

	# output
	var out: int = fn.create_node(T_OUTPUT_SDF, Vector2(1000, 140), 0)
	fn.add_connection(biased, 0, out, 0)

	var res: Dictionary = gen.compile()
	if not bool(res.get("success", false)):
		push_error("LASpherePlanetGenerator compile FAILED: " + str(res))
	return gen
