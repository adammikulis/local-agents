class_name LAPlanetShape
extends RefCounted


# Resolutions of the measurement below, not shape.
const CDF_SAMPLES: int = 8192
const CURVE_POINTS: int = 65
const CURVE_BAKE: int = 512
## Shortest wavelength the seeded relief carries, metres.
const FINEST_WAVELENGTH_M: float = 4.0e2
# Fractal cave tunnels carved into the crust below the weathering front.
const CAVE_SIZE_M: float = 2.0e4
const CAVE_THRESHOLD: float = 0.09
const CAVE_STRENGTH: float = 40.0
const CAVE_DEPTH_FADE_M: float = 4.7e3


## Octaves that carry a cascade from `long_m` down to `short_m`.
static func octaves_between(long_m: float, short_m: float) -> int:
	return maxi(int(ceil(log(maxf(long_m / maxf(short_m, 1.0), 2.0)) / log(2.0))), 1)

## Elevation, metres, at cumulative surface-area fraction `u`: the declared hypsographic curve read
## backwards, linear between its break points.
static func elevation_at_area(u: float) -> float:
	var a: Array[float] = LAPhysical.HYPSOMETRY_AREA_BELOW
	var e: Array[float] = LAPhysical.HYPSOMETRY_ELEVATION_M
	var t: float = clampf(u, a[0], a[a.size() - 1])
	for i in range(1, a.size()):
		if t <= a[i]:
			var span: float = a[i] - a[i - 1]
			return e[i - 1] if span <= 0.0 else e[i - 1] \
				+ (t - a[i - 1]) / span * (e[i] - e[i - 1])
	return e[e.size() - 1]


## Even directions over the sphere: a Fibonacci lattice, no clustering at the poles.
static func directions(n: int) -> PackedVector3Array:
	var out: PackedVector3Array = PackedVector3Array()
	var golden: float = PI * (3.0 - sqrt(5.0))
	for i in range(maxi(n, 1)):
		var y: float = 1.0 - 2.0 * (float(i) + 0.5) / float(maxi(n, 1))
		out.append(Vector3(cos(golden * i), 0.0, sin(golden * i)) * sqrt(maxf(0.0, 1.0 - y * y))
			+ Vector3.UP * y)
	return out


## THE PROBABILITY INTEGRAL TRANSFORM: the cascade sampled over the body, sorted, read against the
## declared curve at the same quantiles. No layer carries an amplitude of its own.
static func hypsometric_curve(values: PackedFloat32Array) -> Curve:
	var sorted: PackedFloat32Array = values.duplicate()
	sorted.sort()
	var n: int = sorted.size()
	if n < 2 or not (sorted[n - 1] - sorted[0] > 0.0):
		return null
	var lo: float = sorted[0]
	var span: float = sorted[n - 1] - lo
	var c: Curve = Curve.new()
	c.min_value = LAPhysical.HYPSOMETRY_DEEPEST_M
	c.max_value = LAPhysical.HYPSOMETRY_HIGHEST_M
	c.bake_resolution = CURVE_BAKE
	for k in range(CURVE_POINTS):
		var q: float = float(k) / float(CURVE_POINTS - 1)
		var idx: int = clampi(int(round(q * float(n - 1))), 0, n - 1)
		var i: int = c.add_point(Vector2(clampf((sorted[idx] - lo) / span, 0.0, 1.0),
			elevation_at_area(q)))
		c.set_point_left_mode(i, Curve.TANGENT_LINEAR)
		c.set_point_right_mode(i, Curve.TANGENT_LINEAR)
	return c


## THE ONE DECLARATION OF THE BODY'S STARTING SHAPE: wavelengths follow the radius, relief follows the
## hypsographic curve.
static func opts(r_m: float, seed_val: int, caves: bool) -> Dictionary:
	# Wavelength of the continent-ocean pattern on this body.
	var lambda0: float = TAU * maxf(r_m, 1.0) / float(LAPhysical.TOPOGRAPHY_DOMINANT_HARMONIC_DEGREE)
	var cross: float = LAPhysical.TOPOGRAPHY_SELF_AFFINE_CROSSOVER_M
	return {
		"radius": r_m,
		"seed": seed_val,
		"continental_size": lambda0,
		"continental_octaves": octaves_between(lambda0, cross),
		"continental_gain": pow(2.0, -LAPhysical.TOPOGRAPHY_LONG_HURST),
		"detail_size": cross,
		"detail_octaves": octaves_between(cross, FINEST_WAVELENGTH_M),
		"detail_gain": pow(2.0, -LAPhysical.TOPOGRAPHY_SHORT_HURST),
		# Spectral continuity at the crossover.
		"detail_weight": pow(cross / lambda0, LAPhysical.TOPOGRAPHY_LONG_HURST),
		"caves_enabled": caves,
		"cave_size": CAVE_SIZE_M,
		"cave_threshold": CAVE_THRESHOLD,
		"cave_strength": CAVE_STRENGTH,
		"cave_depth_fade": CAVE_DEPTH_FADE_M,
	}
