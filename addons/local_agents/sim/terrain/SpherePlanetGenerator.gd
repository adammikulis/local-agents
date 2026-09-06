class_name LASpherePlanetGenerator
extends RefCounted


# SdfSphere input ports: 0=x 1=y 2=z 3=radius (x/y/z autoconnect to world coords when left unwired).

var _radius: float = 0.0
## The cascade and the curve the graph is compiled from, kept so the crust's radius along a direction is
## read from the same expression the mesher's SDF is: length(p) - radius - elevation(p_hat).
var _cont: ZN_FastNoiseLite = null
var _detail: ZN_FastNoiseLite = null
var _det_weight: float = 0.0
var _curve: Curve = null
var _lo: float = 0.0
var _inv_span: float = 0.0

## Planet mean crust radius: the sphere the relief rides on, and the zero of every elevation here.
func radius() -> float:
	return _radius


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


## Elevation of the crust over the mean radius along a body-frame direction, metres. THE SAME EXPRESSION
## the compiled graph evaluates, so a radius read here and a surface the mesher builds are one surface.
func elevation_at(dir: Vector3) -> float:
	if _curve == null:
		return NAN
	var p: Vector3 = dir.normalized() * _radius
	var v: float = _cont.get_noise_3d(p.x, p.y, p.z) \
		+ _det_weight * _detail.get_noise_3d(p.x, p.y, p.z)
	return _curve.sample_baked(clampf((v - _lo) * _inv_span, 0.0, 1.0))


## The crust's elevation over an equirectangular lattice, row 0 at the north pole: what LAWaterFill lays
## the body's water over.
func elevation_lattice(nlat: int, nlon: int) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	if _curve == null or nlat <= 0 or nlon <= 0:
		return out
	out.resize(nlat * nlon)
	for i in nlat:
		for j in nlon:
			out[i * nlon + j] = elevation_at(LAWaterFill.node_dir(i, j, nlat, nlon))
	return out


func build(opts: Dictionary = {}) -> VoxelGeneratorGraph:
	_radius = float(opts.get("radius", 0.0))
	var seed_val: int = int(opts.get("seed", 1337))
	_det_weight = float(opts.get("detail_weight", 0.0))

	# ONE CASCADE, BENT AT THE CROSSOVER: planetary wavelengths fall as l^-2, continental ones are
	# self-affine at a shallower exponent, and these two layers are that one cascade either side of it.
	_cont = _cascade(float(opts.get("continental_size", 1.0)),
		int(opts.get("continental_octaves", 1)), float(opts.get("continental_gain", 0.5)), seed_val)
	_detail = _cascade(float(opts.get("detail_size", 1.0)),
		int(opts.get("detail_octaves", 1)), float(opts.get("detail_gain", 0.707)), seed_val + 7)

	var samples: PackedFloat32Array = PackedFloat32Array()
	for d: Vector3 in LAPlanetShape.directions(LAPlanetShape.CDF_SAMPLES):
		var p: Vector3 = d * _radius
		samples.append(_cont.get_noise_3d(p.x, p.y, p.z)
			+ _det_weight * _detail.get_noise_3d(p.x, p.y, p.z))
	var curve: Curve = LAPlanetShape.hypsometric_curve(samples)
	if curve == null:
		push_error("LASpherePlanetGenerator: the relief cascade is flat over the body, so it carries no "
			+ "distribution to lay the hypsographic curve along.")
		return null
	var sorted: PackedFloat32Array = samples.duplicate()
	sorted.sort()
	_lo = sorted[0]
	_inv_span = 1.0 / (sorted[sorted.size() - 1] - _lo)
	_curve = curve
	_curve.bake()

	var gen: VoxelGeneratorGraph = VoxelGeneratorGraph.new()
	var fn: VoxelGraphFunction = gen.get_main_function()
	fn.clear()

	# sphere: length(p) - radius
	var sphere: int = fn.create_node(VoxelGraphFunction.NODE_SDF_SPHERE, Vector2(0, 0), 0)
	fn.set_node_default_input(sphere, 3, _radius)

	var cont_noise: int = fn.create_node(VoxelGraphFunction.NODE_FAST_NOISE_3D, Vector2(0, 220), 0)
	fn.set_node_param_by_name(cont_noise, "noise", _cont)
	var det_noise: int = fn.create_node(VoxelGraphFunction.NODE_FAST_NOISE_3D, Vector2(0, 380), 0)
	fn.set_node_param_by_name(det_noise, "noise", _detail)
	var det_mul: int = fn.create_node(VoxelGraphFunction.NODE_MULTIPLY, Vector2(200, 380), 0)
	fn.add_connection(det_noise, 0, det_mul, 0)
	fn.set_node_default_input(det_mul, 1, _det_weight)
	var cascade: int = fn.create_node(VoxelGraphFunction.NODE_ADD, Vector2(400, 300), 0)
	fn.add_connection(cont_noise, 0, cascade, 0)
	fn.add_connection(det_mul, 0, cascade, 1)

	# The cascade's own range mapped onto the curve's domain, so the curve is read at its own quantile.
	var norm_mul: int = fn.create_node(VoxelGraphFunction.NODE_MULTIPLY, Vector2(560, 300), 0)
	fn.add_connection(cascade, 0, norm_mul, 0)
	fn.set_node_default_input(norm_mul, 1, _inv_span)
	var norm: int = fn.create_node(VoxelGraphFunction.NODE_ADD, Vector2(700, 300), 0)
	fn.add_connection(norm_mul, 0, norm, 0)
	fn.set_node_default_input(norm, 1, -_lo * _inv_span)

	# elevation, metres over the mean crust radius
	var elev: int = fn.create_node(VoxelGraphFunction.NODE_CURVE, Vector2(860, 300), 0)
	fn.set_node_param_by_name(elev, "curve", curve)
	fn.add_connection(norm, 0, elev, 0)

	var surface: int = fn.create_node(VoxelGraphFunction.NODE_SUBTRACT, Vector2(1020, 140), 0)
	fn.add_connection(sphere, 0, surface, 0)
	fn.add_connection(elev, 0, surface, 1)

	var out: int = fn.create_node(VoxelGraphFunction.NODE_OUTPUT_SDF, Vector2(1460, 140), 0)
	fn.add_connection(surface, 0, out, 0)

	var res: Dictionary = gen.compile()
	if not bool(res.get("success", false)):
		push_error("LASpherePlanetGenerator compile FAILED: " + str(res))
	return gen
