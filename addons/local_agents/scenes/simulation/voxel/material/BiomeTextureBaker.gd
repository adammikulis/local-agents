class_name LABiomeTextureBaker
extends RefCounted

## Bakes the field's near-GROUND climate into a 6-layer RGBA8 Texture2DArray — one texel per SphereGrid
## surface column — so the terrain shader can colour by CLIMATE (moisture + temperature), not altitude
## alone. This is the "one green lawn -> distinct places" bridge: a dry plateau reads savanna/desert while a
## humid coast reads jungle, purely because the emergent field is drier/wetter there. No per-place scripting.
##
## Mirrors LACoverTextureBaker exactly (same grid, same gnomonic pack) so the terrain shader recovers the
## texel with the SAME face math the water renderer already uses. ONE O(surf_count) reduction, run off the
## live CPU readback the atmosphere refresh already produced. Cell layout: c = s*depth + r.
##
## Channels (RGBA8, per surface column):
##   R = relative humidity of the near-ground air (moisture / sat(T)), 0 arid .. 1 humid -> dry<->lush axis
##   G = warmth, temperature °C remapped over a cold..hot band, 0 tundra-cold .. 1 tropical-hot
##   B = snowpack presence (cold-wet flag), lets the shader bias toward frost/tundra tint
##   A = valid flag (255 once baked) so the shader FALLS BACK to altitude-only bands before the first bake
##       (a fresh/ headless launch samples black -> A=0 -> unchanged legacy look, never a broken colour).
## (Explicit types only — no ':=' inferred typing.)

const WARM_COLD_C: float = -25.0     # temperature that reads fully "tundra cold" (G = 0)
const WARM_HOT_C: float = 40.0       # temperature that reads fully "tropical hot" (G = 1)
const RH_LUSH: float = 1.2           # relative humidity that reads fully lush/jungle (R = 1); ~saturation.
                                     # Tuned so mean land (~0.5 RH) reads grassland, dry interiors desert,
                                     # saturated/coastal air jungle — an Earth-like desert/steppe/jungle spread.

var _res: int = 0
var _depth: int = 0
var _surf: int = 0
var _core: float = 0.0
var _cell: float = 0.0
var _sea: float = 0.0
var _sat_base: float = 0.06
var _sat_gain: float = 0.055
var _sat_ref: float = 22.0

var _imgs: Array = []
var _tex: Texture2DArray = null
var _cell_of: PackedInt32Array = PackedInt32Array()   # per-column near-ground climate cell (reused each bake)
var _rh: PackedFloat32Array = PackedFloat32Array()    # per-column relative humidity (reused each bake)


func setup(grid: RefCounted, sea_r: float, sat_base: float, sat_gain: float, sat_ref: float) -> void:
	_res = grid.res
	_depth = grid.depth
	_surf = grid.surf_count
	_core = grid.core_radius
	_cell = grid.cell_size
	_sea = sea_r
	_sat_base = sat_base
	_sat_gain = sat_gain
	_sat_ref = sat_ref
	_imgs = []
	for f in range(6):
		_imgs.append(Image.create(_res, _res, false, Image.FORMAT_RGBA8))


func texture() -> Texture2DArray:
	return _tex


## Reduce each surface column to its near-ground climate, then pack the 6-layer texture. `moisture`/`temp`
## are the field's live per-cell CPU readback; `snow`/`solid` gate the frost flag + the surface cell.
func bake(moisture: PackedFloat32Array, temp: PackedFloat32Array, snow: PackedFloat32Array, solid: PackedByteArray, cell_count: int) -> void:
	if _surf <= 0 or moisture.size() != cell_count or temp.size() != cell_count:
		return
	var has_snow: bool = snow.size() == cell_count
	var depth: int = _depth
	var res: int = _res
	var rr2: int = res * res
	# Radial layer nearest the sea shell — the fallback climate cell for an all-void (ocean/sky) column.
	var sea_r_layer: int = clampi(int((_sea - _core) / _cell), 0, depth - 1)

	# Pass 1: per-column near-ground climate cell + RELATIVE HUMIDITY (moisture vs the dewpoint sat(T)). RH is
	# the physical wetness signal: RH >= ~1 means the air is saturated -> it condenses/rains there -> lush
	# jungle; RH near 0 is bone-dry -> desert. Anchored ABSOLUTELY at saturation (RH_LUSH), NOT relative to the
	# planet's range, so the biome of a place depends on its own climate — and ocean columns (always saturated)
	# never skew land. Purely from the emergent moisture field: dry interiors self-differentiate from humid coasts.
	_cell_of.resize(_surf)
	_rh.resize(_surf)
	var rh_sum: float = 0.0
	var land_n: int = 0
	var land_r_min: int = clampi(int((_sea - _core) / _cell), 0, depth - 1)
	for s in range(_surf):
		var base: int = s * depth
		var surf_r: int = -1
		for r in range(depth - 1, -1, -1):
			if solid[base + r] != 0:
				surf_r = r
				break
		var cell: int = base + sea_r_layer
		if surf_r >= 0:
			cell = base + mini(surf_r + 1, depth - 1)
		_cell_of[s] = cell
		var t: float = temp[cell]
		var sat: float = _sat_base * exp(_sat_gain * (t - _sat_ref))
		var rh: float = moisture[cell] / maxf(sat, 1.0e-4)
		_rh[s] = rh
		if surf_r >= land_r_min:
			rh_sum += rh
			land_n += 1

	if OS.has_environment("LA_BIOME_DEBUG"):
		var rh_mean: float = rh_sum / float(maxi(land_n, 1))
		print("BIOME_BAKE={rh_mean:%.3f, land:%d, surf:%d, lush_at:%.2f}" % [rh_mean, land_n, _surf, RH_LUSH])

	# Pass 2: pack. Wetness = RH anchored at saturation (RH_LUSH -> fully lush); warmth/frost absolute.
	for f in range(6):
		var bytes: PackedByteArray = PackedByteArray()
		bytes.resize(rr2 * 4)
		var s0: int = f * rr2
		for k in range(rr2):
			var s: int = s0 + k
			var cell: int = _cell_of[s]
			var t: float = temp[cell]
			var wet: float = clampf(_rh[s] / RH_LUSH, 0.0, 1.0)
			var warm: float = clampf((t - WARM_COLD_C) / (WARM_HOT_C - WARM_COLD_C), 0.0, 1.0)
			var frost: float = 0.0
			if has_snow:
				frost = clampf(snow[cell] * 3.0, 0.0, 1.0)
			# Pixel (x=i, y=j) — the SAME layout the shader recovers via inverse gnomonic.
			var i: int = k / res
			var j: int = k - i * res
			var bi: int = (j * res + i) * 4
			bytes[bi + 0] = int(wet * 255.0)
			bytes[bi + 1] = int(warm * 255.0)
			bytes[bi + 2] = int(frost * 255.0)
			bytes[bi + 3] = 255
		_imgs[f].set_data(res, res, false, Image.FORMAT_RGBA8, bytes)
	if _tex == null:
		_tex = Texture2DArray.new()
		_tex.create_from_images(_imgs)
	else:
		for f in range(6):
			_tex.update_layer(_imgs[f], f)
