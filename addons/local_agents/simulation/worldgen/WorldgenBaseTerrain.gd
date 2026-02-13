extends RefCounted

static func build_noise(seed: int, frequency: float, octaves: int, lacunarity: float = 2.0, gain: float = 0.5) -> FastNoiseLite:
    var noise = FastNoiseLite.new()
    noise.seed = seed
    noise.frequency = maxf(0.001, frequency)
    noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    noise.fractal_type = FastNoiseLite.FRACTAL_FBM
    noise.fractal_octaves = maxi(1, octaves)
    noise.fractal_lacunarity = clampf(lacunarity, 1.1, 4.0)
    noise.fractal_gain = clampf(gain, 0.05, 1.0)
    return noise

static func sample_surface_noise(surface_noise: FastNoiseLite, x: int, z: int, smoothing: float) -> float:
    var smooth = clampf(smoothing, 0.0, 1.0)
    var center = surface_noise.get_noise_2d(float(x), float(z))
    if smooth <= 0.001:
        return center
    var east = surface_noise.get_noise_2d(float(x + 1), float(z))
    var west = surface_noise.get_noise_2d(float(x - 1), float(z))
    var north = surface_noise.get_noise_2d(float(x), float(z + 1))
    var south = surface_noise.get_noise_2d(float(x), float(z - 1))
    var average = (center + east + west + north + south) / 5.0
    return lerpf(center, average, smooth)

static func surface_height(surface_value: float, config, voxel_world_height: int) -> int:
    var base_height = clampi(int(config.voxel_surface_height_base), 1, voxel_world_height - 2)
    var height_range = maxi(1, int(config.voxel_surface_height_range))
    var max_surface = voxel_world_height - 2
    var surface = base_height + int(round(surface_value * float(height_range)))
    return clampi(surface, 1, max_surface)

static func estimate_slope(surface_noise: FastNoiseLite, x: int, z: int) -> float:
    var center = surface_noise.get_noise_2d(float(x), float(z))
    var east = surface_noise.get_noise_2d(float(x + 1), float(z))
    var south = surface_noise.get_noise_2d(float(x), float(z + 1))
    return clampf(absf(center - east) + absf(center - south), 0.0, 1.0)

static func island_bias(x: int, z: int, width: int, height: int, continental: float, tectonic: float) -> float:
    var nx = 0.0
    var nz = 0.0
    if width > 1:
        nx = (float(x) / float(width - 1)) * 2.0 - 1.0
    if height > 1:
        nz = (float(z) / float(height - 1)) * 2.0 - 1.0
    var radial = clampf(1.0 - sqrt(nx * nx + nz * nz), 0.0, 1.0)
    var continental_lift = clampf((continental - 0.42) * 1.8, 0.0, 1.0)
    var hotspot_islands = clampf((tectonic - 0.62) * 2.4, 0.0, 1.0) * clampf((0.46 - continental) * 2.2, 0.0, 1.0)
    return clampf(radial * 0.58 + continental_lift * 0.32 + hotspot_islands * 0.58, 0.0, 1.0)
