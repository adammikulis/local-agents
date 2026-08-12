class_name LASpherePlanetGenerator
extends RefCounted


const T_OUTPUT_SDF: int = 4
const T_ADD: int = 5
const T_SUBTRACT: int = 6
const T_MULTIPLY: int = 7
const T_ABS: int = 11
const T_MIN: int = 16
const T_MAX: int = 17
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
	var ridge_relief: float = float(opts.get("ridge_relief", 0.0))
	var ridge_size: float = float(opts.get("ridge_size", 90.0))
	var ridge_octaves: int = maxi(1, int(opts.get("ridge_octaves", 4)))
	var caves_enabled: bool = bool(opts.get("caves_enabled", true))
	var cave_size: float = maxf(1.0, float(opts.get("cave_size", 70.0)))
	var cave_threshold: float = float(opts.get("cave_threshold", 0.08))
	var cave_strength: float = float(opts.get("cave_strength", 40.0))
	var cave_depth_fade: float = maxf(0.0, float(opts.get("cave_depth_fade", 24.0)))

	var cont: ZN_FastNoiseLite = ZN_FastNoiseLite.new()
	cont.noise_type = ZN_FastNoiseLite.TYPE_OPEN_SIMPLEX_2S
	cont.seed = seed_val
	cont.period = maxf(1.0, feature_size)
	cont.fractal_type = ZN_FastNoiseLite.FRACTAL_FBM
	cont.fractal_octaves = maxi(2, octaves + 1)
	cont.fractal_lacunarity = 2.0
	cont.fractal_gain = 0.5

	# DETAIL: low-amplitude simplex fBm so hillsides have texture (not glass) without drowning the cells.
	var detail: ZN_FastNoiseLite = ZN_FastNoiseLite.new()
	detail.noise_type = ZN_FastNoiseLite.TYPE_OPEN_SIMPLEX_2S
	detail.seed = seed_val + 7
	detail.period = maxf(1.0, detail_size)
	detail.fractal_type = ZN_FastNoiseLite.FRACTAL_FBM
	detail.fractal_octaves = 2
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

	# RIDGES: ridged multifractal → branching ridge lines + valleys (the dendritic river-valley network).
	var ridge: ZN_FastNoiseLite = ZN_FastNoiseLite.new()
	ridge.noise_type = ZN_FastNoiseLite.TYPE_OPEN_SIMPLEX_2S
	ridge.seed = seed_val + 23
	ridge.period = maxf(1.0, ridge_size)
	ridge.fractal_type = ZN_FastNoiseLite.FRACTAL_RIDGED
	ridge.fractal_octaves = ridge_octaves
	ridge.fractal_lacunarity = 2.0
	ridge.fractal_gain = 0.5

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

	# ridge relief = ridged * ridge_relief  (branching ridge lines → river valleys between)
	var ridge_noise: int = fn.create_node(T_FAST_NOISE_3D, Vector2(0, 640), 0)
	fn.set_node_param_by_name(ridge_noise, "noise", ridge)
	var ridge_mul: int = fn.create_node(T_MULTIPLY, Vector2(200, 640), 0)
	fn.add_connection(ridge_noise, 0, ridge_mul, 0)
	fn.set_node_default_input(ridge_mul, 1, ridge_relief)

	# relief += basin  (undulate so closed depressions exist for water to pool)
	var relief_sum2: int = fn.create_node(T_ADD, Vector2(500, 400), 0)
	fn.add_connection(relief_sum, 0, relief_sum2, 0)
	fn.add_connection(basin_mul, 0, relief_sum2, 1)

	# relief += ridge  (carve the dendritic valley network)
	var relief_sum3: int = fn.create_node(T_ADD, Vector2(560, 460), 0)
	fn.add_connection(relief_sum2, 0, relief_sum3, 0)
	fn.add_connection(ridge_mul, 0, relief_sum3, 1)

	# core = sphere - relief  (raise surface outward where relief is high)
	var core: int = fn.create_node(T_SUBTRACT, Vector2(600, 140), 0)
	fn.add_connection(sphere, 0, core, 0)
	fn.add_connection(relief_sum3, 0, core, 1)

	# biased = core + ocean_bias  (push the whole surface inward => most of the sphere is ocean)
	var biased: int = fn.create_node(T_ADD, Vector2(800, 140), 0)
	fn.add_connection(core, 0, biased, 0)
	fn.set_node_default_input(biased, 1, ocean_bias)

	var final_node: int = biased
	if caves_enabled and cave_strength > 0.0:
		var cave1: ZN_FastNoiseLite = ZN_FastNoiseLite.new()
		cave1.noise_type = ZN_FastNoiseLite.TYPE_OPEN_SIMPLEX_2S
		cave1.seed = seed_val + 101
		cave1.period = cave_size
		cave1.fractal_type = ZN_FastNoiseLite.FRACTAL_FBM
		cave1.fractal_octaves = 3
		cave1.fractal_lacunarity = 2.0
		cave1.fractal_gain = 0.5

		var cave2: ZN_FastNoiseLite = ZN_FastNoiseLite.new()
		cave2.noise_type = ZN_FastNoiseLite.TYPE_OPEN_SIMPLEX_2S
		cave2.seed = seed_val + 211
		cave2.period = cave_size
		cave2.fractal_type = ZN_FastNoiseLite.FRACTAL_FBM
		cave2.fractal_octaves = 3
		cave2.fractal_lacunarity = 2.0
		cave2.fractal_gain = 0.5

		var cn1: int = fn.create_node(T_FAST_NOISE_3D, Vector2(0, 820), 0)
		fn.set_node_param_by_name(cn1, "noise", cave1)
		var cn2: int = fn.create_node(T_FAST_NOISE_3D, Vector2(0, 980), 0)
		fn.set_node_param_by_name(cn2, "noise", cave2)

		# cave_open = cave_threshold - max(|n1|, |n2|)  => >0 only where BOTH noises sit near their zero-set
		var abs1: int = fn.create_node(T_ABS, Vector2(200, 820), 0)
		fn.add_connection(cn1, 0, abs1, 0)
		var abs2: int = fn.create_node(T_ABS, Vector2(200, 980), 0)
		fn.add_connection(cn2, 0, abs2, 0)
		var amax: int = fn.create_node(T_MAX, Vector2(400, 900), 0)
		fn.add_connection(abs1, 0, amax, 0)
		fn.add_connection(abs2, 0, amax, 1)
		var copen: int = fn.create_node(T_SUBTRACT, Vector2(560, 900), 0)
		fn.set_node_default_input(copen, 0, cave_threshold)
		fn.add_connection(amax, 0, copen, 1)

		# void SDF = cave_open * cave_strength  (positive inside a tunnel, negative in solid rock)
		var cvoid: int = fn.create_node(T_MULTIPLY, Vector2(720, 900), 0)
		fn.add_connection(copen, 0, cvoid, 0)
		fn.set_node_default_input(cvoid, 1, cave_strength)

		# DEPTH GATE: depth = -base_sdf ; gate = min(0, depth - cave_depth_fade)
		#   => 0 once we are deeper than cave_depth_fade, strongly negative near/above the surface. Adding it to
		#   the void drives the void negative near the surface, so surface tunnels are suppressed (no holes).
		var depth: int = fn.create_node(T_MULTIPLY, Vector2(720, 60), 0)
		fn.add_connection(biased, 0, depth, 0)
		fn.set_node_default_input(depth, 1, -1.0)
		var dminus: int = fn.create_node(T_SUBTRACT, Vector2(900, 60), 0)
		fn.add_connection(depth, 0, dminus, 0)
		fn.set_node_default_input(dminus, 1, cave_depth_fade)
		var gate: int = fn.create_node(T_MIN, Vector2(1080, 60), 0)
		fn.add_connection(dminus, 0, gate, 0)
		fn.set_node_default_input(gate, 1, 0.0)

		# gated void = void + gate  ; carve = max(base_sdf, gated void)
		var gvoid: int = fn.create_node(T_ADD, Vector2(1080, 900), 0)
		fn.add_connection(cvoid, 0, gvoid, 0)
		fn.add_connection(gate, 0, gvoid, 1)
		var carved: int = fn.create_node(T_MAX, Vector2(1260, 500), 0)
		fn.add_connection(biased, 0, carved, 0)
		fn.add_connection(gvoid, 0, carved, 1)
		final_node = carved

	# output
	var out: int = fn.create_node(T_OUTPUT_SDF, Vector2(1460, 140), 0)
	fn.add_connection(final_node, 0, out, 0)

	var res: Dictionary = gen.compile()
	if not bool(res.get("success", false)):
		push_error("LASpherePlanetGenerator compile FAILED: " + str(res))
	return gen
