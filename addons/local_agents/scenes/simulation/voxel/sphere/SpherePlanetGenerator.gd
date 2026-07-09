class_name LASpherePlanetGenerator
extends RefCounted

## Builds the NATIVE compiled voxel-graph generator for a spherical planet (Phase A1 terrain crux).
##
## The planet is one SDF: `sdf(p) = (length(p) - radius) - amp * fbm_noise3d(p)`, output to OUTPUT_SDF.
##   - `length(p) - radius` is a solid ball (negative INSIDE = rock, positive outside = air) — matches the
##     existing `is_solid = sdf < 0` convention, but now radial in every direction (no box axes, no heightmap).
##   - subtracting scaled 3D FBM pushes the surface OUTWARD where noise is high → hills/valleys, and because
##     it's true 3D noise it yields real overhangs/arches/cave-prone rock, not a height function of (lat,lon).
## Everything runs in the native `VoxelGeneratorGraph` (compiled, SIMD) — NO per-voxel GDScript (native/Big-O
## mandate). godot_voxel's VoxelLodTerrain gives distance-LOD for free (Big-O: far surface meshes coarser).
## (Explicit types only — no ':=' .)

# VoxelGraphFunction NODE_* type ids (from this build's ClassDB):
const T_OUTPUT_SDF: int = 4
const T_SUBTRACT: int = 6
const T_MULTIPLY: int = 7
const T_SDF_SPHERE: int = 32
const T_FAST_NOISE_3D: int = 40

# SdfSphere input ports: 0=x 1=y 2=z 3=radius (x/y/z autoconnect to world coords when left unwired).

var _radius: float = 250.0
var _sea_radius: float = 232.0

## Planet solid radius (mean sea-floor sphere the terrain noise rides on).
func radius() -> float:
	return _radius

## Radius of the spherical sea shell (where the ocean surface sits).
func sea_radius() -> float:
	return _sea_radius


## Build + compile the generator. opts: radius, sea_radius, relief (noise amplitude, world units),
## feature_size (terrain wavelength, world units), octaves, seed. Returns the compiled VoxelGeneratorGraph.
## Pushes an error + returns a still-usable generator if compile fails (caller should check compile()).
func build(opts: Dictionary = {}) -> VoxelGeneratorGraph:
	_radius = float(opts.get("radius", 250.0))
	_sea_radius = float(opts.get("sea_radius", _radius * 0.93))
	var relief: float = float(opts.get("relief", 26.0))
	var feature_size: float = float(opts.get("feature_size", 46.0))
	var octaves: int = int(opts.get("octaves", 4))
	var seed_val: int = int(opts.get("seed", 1337))

	var noise: ZN_FastNoiseLite = ZN_FastNoiseLite.new()
	noise.noise_type = ZN_FastNoiseLite.TYPE_OPEN_SIMPLEX_2S
	noise.seed = seed_val
	noise.period = maxf(1.0, feature_size)
	noise.fractal_type = ZN_FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5

	var gen: VoxelGeneratorGraph = VoxelGeneratorGraph.new()
	var fn: VoxelGraphFunction = gen.get_main_function()
	fn.clear()

	# sphere: length(p) - radius  (radius via default input 3; x/y/z autoconnect)
	var sphere: int = fn.create_node(T_SDF_SPHERE, Vector2(0, 0), 0)
	fn.set_node_default_input(sphere, 3, _radius)

	# noise: fbm 3D of world pos (x/y/z autoconnect)
	var noise_id: int = fn.create_node(T_FAST_NOISE_3D, Vector2(0, 200), 0)
	fn.set_node_param_by_name(noise_id, "noise", noise)

	# relief = noise * amp
	var mul: int = fn.create_node(T_MULTIPLY, Vector2(200, 200), 0)
	fn.add_connection(noise_id, 0, mul, 0)
	fn.set_node_default_input(mul, 1, relief)

	# sdf = sphere - relief  (raise surface outward where noise is high)
	var sub: int = fn.create_node(T_SUBTRACT, Vector2(400, 100), 0)
	fn.add_connection(sphere, 0, sub, 0)
	fn.add_connection(mul, 0, sub, 1)

	# output
	var out: int = fn.create_node(T_OUTPUT_SDF, Vector2(600, 100), 0)
	fn.add_connection(sub, 0, out, 0)

	var res: Dictionary = gen.compile()
	if not bool(res.get("success", false)):
		push_error("LASpherePlanetGenerator compile FAILED: " + str(res))
	return gen
