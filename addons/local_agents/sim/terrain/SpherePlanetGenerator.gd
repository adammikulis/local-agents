class_name LASpherePlanetGenerator
extends RefCounted



# SdfSphere input ports: 0=x 1=y 2=z 3=radius (x/y/z autoconnect to world coords when left unwired).

var _radius: float = 0.0
var _sea_radius: float = 0.0

## Planet solid radius (the sea-level sphere the relief rides on).
func radius() -> float:
	return _radius

## Radius of the spherical sea shell (where the ocean surface sits).
func sea_radius() -> float:
	return _sea_radius


func _cascade(p_period: float, p_octaves: int, p_gain: float, p_seed: int) -> ZN_FastNoiseLite:
	var n: ZN_FastNoiseLite = ZN_FastNoiseLite.new()
	n.noise_type = ZN_FastNoiseLite.TYPE_OPEN_SIMPLEX_2S
	n.seed = p_seed
	n.period = maxf(1.0, p_period)
	n.fractal_type = ZN_FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = maxi(1, p_octaves)
	n.fractal_lacunarity = 2.0
	n.fractal_gain = p_gain
	return n


func build(opts: Dictionary = {}) -> VoxelGeneratorGraph:
	_radius = float(opts.get("radius", 0.0))
	_sea_radius = float(opts.get("sea_radius", _radius))
	var seed_val: int = int(opts.get("seed", 1337))
	var det_weight: float = float(opts.get("detail_weight", 0.0))
	var caves_enabled: bool = bool(opts.get("caves_enabled", true))
	var cave_size: float = maxf(1.0, float(opts.get("cave_size", 2.0e4)))
	var cave_threshold: float = float(opts.get("cave_threshold", 0.09))
	var cave_strength: float = float(opts.get("cave_strength", 40.0))
	var cave_depth_fade: float = maxf(0.0, float(opts.get("cave_depth_fade", 4.7e3)))

	# ONE CASCADE, BENT AT THE CROSSOVER: planetary wavelengths fall as l^-2, continental ones are
	# self-affine at a shallower exponent, and these two layers are that one cascade either side of it.
	var cont: ZN_FastNoiseLite = _cascade(float(opts.get("continental_size", 1.0)),
		int(opts.get("continental_octaves", 1)), float(opts.get("continental_gain", 0.5)), seed_val)
	var detail: ZN_FastNoiseLite = _cascade(float(opts.get("detail_size", 1.0)),
		int(opts.get("detail_octaves", 1)), float(opts.get("detail_gain", 0.707)), seed_val + 7)

	var samples: PackedFloat32Array = PackedFloat32Array()
	for d: Vector3 in LAPlanetShape.directions(LAPlanetShape.CDF_SAMPLES):
		var p: Vector3 = d * _radius
		samples.append(cont.get_noise_3d(p.x, p.y, p.z)
			+ det_weight * detail.get_noise_3d(p.x, p.y, p.z))
	var curve: Curve = LAPlanetShape.hypsometric_curve(samples)
	if curve == null:
		push_error("LASpherePlanetGenerator: the relief cascade is flat over the body, so it carries no "
			+ "distribution to lay the hypsographic curve along.")
		return null
	var sorted: PackedFloat32Array = samples.duplicate()
	sorted.sort()
	var lo: float = sorted[0]
	var inv_span: float = 1.0 / (sorted[sorted.size() - 1] - lo)

	var gen: VoxelGeneratorGraph = VoxelGeneratorGraph.new()
	var fn: VoxelGraphFunction = gen.get_main_function()
	fn.clear()

	# sphere: length(p) - radius
	var sphere: int = fn.create_node(VoxelGraphFunction.NODE_SDF_SPHERE, Vector2(0, 0), 0)
	fn.set_node_default_input(sphere, 3, _radius)

	var cont_noise: int = fn.create_node(VoxelGraphFunction.NODE_FAST_NOISE_3D, Vector2(0, 220), 0)
	fn.set_node_param_by_name(cont_noise, "noise", cont)
	var det_noise: int = fn.create_node(VoxelGraphFunction.NODE_FAST_NOISE_3D, Vector2(0, 380), 0)
	fn.set_node_param_by_name(det_noise, "noise", detail)
	var det_mul: int = fn.create_node(VoxelGraphFunction.NODE_MULTIPLY, Vector2(200, 380), 0)
	fn.add_connection(det_noise, 0, det_mul, 0)
	fn.set_node_default_input(det_mul, 1, det_weight)
	var cascade: int = fn.create_node(VoxelGraphFunction.NODE_ADD, Vector2(400, 300), 0)
	fn.add_connection(cont_noise, 0, cascade, 0)
	fn.add_connection(det_mul, 0, cascade, 1)

	# The cascade's own range mapped onto the curve's domain, so the curve is read at its own quantile.
	var norm_mul: int = fn.create_node(VoxelGraphFunction.NODE_MULTIPLY, Vector2(560, 300), 0)
	fn.add_connection(cascade, 0, norm_mul, 0)
	fn.set_node_default_input(norm_mul, 1, inv_span)
	var norm: int = fn.create_node(VoxelGraphFunction.NODE_ADD, Vector2(700, 300), 0)
	fn.add_connection(norm_mul, 0, norm, 0)
	fn.set_node_default_input(norm, 1, -lo * inv_span)

	# elevation, metres above the sea shell
	var elev: int = fn.create_node(VoxelGraphFunction.NODE_CURVE, Vector2(860, 300), 0)
	fn.set_node_param_by_name(elev, "curve", curve)
	fn.add_connection(norm, 0, elev, 0)

	var surface: int = fn.create_node(VoxelGraphFunction.NODE_SUBTRACT, Vector2(1020, 140), 0)
	fn.add_connection(sphere, 0, surface, 0)
	fn.add_connection(elev, 0, surface, 1)

	var final_node: int = surface
	if caves_enabled and cave_strength > 0.0:
		var cave1: ZN_FastNoiseLite = _cascade(cave_size, 3, 0.5, seed_val + 101)
		var cave2: ZN_FastNoiseLite = _cascade(cave_size, 3, 0.5, seed_val + 211)

		var cn1: int = fn.create_node(VoxelGraphFunction.NODE_FAST_NOISE_3D, Vector2(0, 820), 0)
		fn.set_node_param_by_name(cn1, "noise", cave1)
		var cn2: int = fn.create_node(VoxelGraphFunction.NODE_FAST_NOISE_3D, Vector2(0, 980), 0)
		fn.set_node_param_by_name(cn2, "noise", cave2)

		# cave_open = cave_threshold - max(|n1|, |n2|)  => >0 only where BOTH noises sit near their zero-set
		var abs1: int = fn.create_node(VoxelGraphFunction.NODE_ABS, Vector2(200, 820), 0)
		fn.add_connection(cn1, 0, abs1, 0)
		var abs2: int = fn.create_node(VoxelGraphFunction.NODE_ABS, Vector2(200, 980), 0)
		fn.add_connection(cn2, 0, abs2, 0)
		var amax: int = fn.create_node(VoxelGraphFunction.NODE_MAX, Vector2(400, 900), 0)
		fn.add_connection(abs1, 0, amax, 0)
		fn.add_connection(abs2, 0, amax, 1)
		var copen: int = fn.create_node(VoxelGraphFunction.NODE_SUBTRACT, Vector2(560, 900), 0)
		fn.set_node_default_input(copen, 0, cave_threshold)
		fn.add_connection(amax, 0, copen, 1)

		# void SDF = cave_open * cave_strength  (positive inside a tunnel, negative in solid rock)
		var cvoid: int = fn.create_node(VoxelGraphFunction.NODE_MULTIPLY, Vector2(720, 900), 0)
		fn.add_connection(copen, 0, cvoid, 0)
		fn.set_node_default_input(cvoid, 1, cave_strength)

		# Karst gates: open in the top cave_depth_fade metres, and only above base level (the sea).
		var dplus: int = fn.create_node(VoxelGraphFunction.NODE_ADD, Vector2(900, 60), 0)
		fn.add_connection(surface, 0, dplus, 0)
		fn.set_node_default_input(dplus, 1, cave_depth_fade)
		var above_sea: int = fn.create_node(VoxelGraphFunction.NODE_ADD, Vector2(900, 160), 0)
		fn.add_connection(sphere, 0, above_sea, 0)
		fn.set_node_default_input(above_sea, 1, _radius - _sea_radius)
		var pair: int = fn.create_node(VoxelGraphFunction.NODE_MIN, Vector2(1080, 110), 0)
		fn.add_connection(dplus, 0, pair, 0)
		fn.add_connection(above_sea, 0, pair, 1)
		var gate: int = fn.create_node(VoxelGraphFunction.NODE_MIN, Vector2(1180, 60), 0)
		fn.add_connection(pair, 0, gate, 0)
		fn.set_node_default_input(gate, 1, 0.0)
		var gvoid: int = fn.create_node(VoxelGraphFunction.NODE_ADD, Vector2(1080, 900), 0)
		fn.add_connection(cvoid, 0, gvoid, 0)
		fn.add_connection(gate, 0, gvoid, 1)
		var carved: int = fn.create_node(VoxelGraphFunction.NODE_MAX, Vector2(1260, 500), 0)
		fn.add_connection(surface, 0, carved, 0)
		fn.add_connection(gvoid, 0, carved, 1)
		final_node = carved

	# output
	var out: int = fn.create_node(VoxelGraphFunction.NODE_OUTPUT_SDF, Vector2(1460, 140), 0)
	fn.add_connection(final_node, 0, out, 0)

	var res: Dictionary = gen.compile()
	if not bool(res.get("success", false)):
		push_error("LASpherePlanetGenerator compile FAILED: " + str(res))
	return gen
