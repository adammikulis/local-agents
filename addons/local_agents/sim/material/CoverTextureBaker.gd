class_name LACoverTextureBaker
extends RefCounted

## Bakes the field's DERIVED condensate into a 6-layer RGBA8 Texture2DArray — one texel per SphereGrid
## surface cell — the ~24 KB render bridge the water-particle renderer samples per particle. The field
## runs on a LOCAL RenderingDevice whose SSBOs can't bind to scene shaders, so a small shared summary
## texture is the honest GPU-first bridge (per-particle motion/draw stays 100% on the GPU). Reduces each
## surface column's radial layers into: R=cloud density, G=fog density, B=precip intensity, A=cold flag
## (cold column -> the shader picks snow over rain). ONE O(cell_count) pass, folded into the ~10Hz atmos
## aggregate refresh. Cell layout matches the grid: c = s*depth + r. (Explicit types only — no ':=' .)

var _res: int = 0
var _depth: int = 0
var _surf: int = 0
var _core: float = 0.0
var _cell: float = 0.0
var _sea: float = 0.0
var _cloud_base: float = 0.0
var _cloud_scan_lo: float = 0.0
var _fog_lo: float = 0.0
var _fog_hi: float = 0.0
var _fog_max_temp: float = 12.0
var _rain_thresh: float = 0.45
var _sat_base: float = 0.06
var _sat_gain: float = 0.055
var _sat_ref: float = 22.0

# Per-surface-column reductions (reused each bake).
var _sc: PackedFloat32Array = PackedFloat32Array()      # cloud density
var _sf: PackedFloat32Array = PackedFloat32Array()      # fog density
var _sp: PackedFloat32Array = PackedFloat32Array()      # precip intensity
var _smin: PackedFloat32Array = PackedFloat32Array()    # min near-surface temperature (cold flag)
var _ssnow: PackedFloat32Array = PackedFloat32Array()   # max snowpack over the column
var _imgs: Array = []
var _tex: Texture2DArray = null


func setup(grid: RefCounted, sea_r: float, fog_max_temp: float, rain_thresh: float, sat_base: float, sat_gain: float, sat_ref: float) -> void:
	_res = grid.res
	_depth = grid.depth
	_surf = grid.surf_count
	_core = grid.core_radius
	_cell = grid.cell_size
	_sea = sea_r
	_cloud_base = sea_r + 8.0        # renderer places cloud particles from here up
	_cloud_scan_lo = sea_r - 8.0     # cloud reduction scans the whole column above ~surface
	_fog_lo = sea_r - 8.0
	_fog_hi = sea_r + 4.0            # fog is the near-ground band only
	_fog_max_temp = fog_max_temp
	_rain_thresh = rain_thresh
	_sat_base = sat_base
	_sat_gain = sat_gain
	_sat_ref = sat_ref
	_sc.resize(_surf)
	_sf.resize(_surf)
	_sp.resize(_surf)
	_smin.resize(_surf)
	_ssnow.resize(_surf)
	_imgs = []
	for f in range(6):
		_imgs.append(Image.create(_res, _res, false, Image.FORMAT_RGBA8))


func texture() -> Texture2DArray:
	return _tex

func cloud_base_r() -> float:
	return _cloud_base

func fog_top_r() -> float:
	return _fog_hi

func fog_lo_r() -> float:
	return _fog_lo

func sea_r() -> float:
	return _sea

func outer_r() -> float:
	return _core + float(_depth) * _cell


## Reduce the field's per-cell condensate over each surface column, then pack the 6-layer texture.
func bake(moisture: PackedFloat32Array, temp: PackedFloat32Array, snow: PackedFloat32Array, solid: PackedByteArray, cell_count: int) -> void:
	if _surf <= 0 or moisture.size() != cell_count or temp.size() != cell_count:
		return
	_sc.fill(0.0)
	_sf.fill(0.0)
	_sp.fill(0.0)
	_smin.fill(1.0e20)
	_ssnow.fill(0.0)
	var has_snow: bool = snow.size() == cell_count
	var depth: int = _depth
	for i in range(cell_count):
		if solid[i] != 0:
			continue
		var s: int = i / depth
		var r: int = i - s * depth
		var radius: float = _core + (float(r) + 0.5) * _cell
		var t: float = temp[i]
		if radius >= _fog_lo and radius <= _fog_hi and t < _smin[s]:
			_smin[s] = t
		if has_snow and snow[i] > _ssnow[s]:
			_ssnow[s] = snow[i]
		var cond: float = moisture[i] - _sat_base * exp(_sat_gain * (t - _sat_ref))
		if cond <= 0.0:
			continue
		# Cloud = the column's condensate ALOFT (altitude split, not temperature — on a planet the
		# condensate is cold-driven, so a temp split would read it all as ground fog). Fog = only the
		# genuinely near-ground cool condensate. So a condensate column lights an aloft cloud particle.
		if radius >= _cloud_scan_lo and cond > _sc[s]:
			_sc[s] = cond
		if radius >= _fog_lo and radius <= _fog_hi and t < _fog_max_temp and cond > _sf[s]:
			_sf[s] = cond
		# Render precip: show falling streaks under the wettest columns (a render threshold below the sim's
		# rain-shed threshold, so gentle precip is visible — the phase is still field-gated, not scripted).
		if cond > 0.2 and cond > _sp[s]:
			_sp[s] = cond
	_pack()


## Pack the per-column reductions into the 6-layer RGBA8 texture. Face f, surface (i,j) -> pixel (x=i, y=j)
## (the process shader recovers (f,i,j) with the SAME gnomonic face math, so this mapping is exact).
func _pack() -> void:
	var res: int = _res
	var rr2: int = res * res
	for f in range(6):
		var bytes: PackedByteArray = PackedByteArray()
		bytes.resize(rr2 * 4)
		var s0: int = f * rr2
		for k in range(rr2):
			var s: int = s0 + k
			var i: int = k / res
			var j: int = k - i * res
			var bi: int = (j * res + i) * 4
			bytes[bi + 0] = int(clamp(_sc[s], 0.0, 1.0) * 255.0)
			bytes[bi + 1] = int(clamp(_sf[s], 0.0, 1.0) * 255.0)
			bytes[bi + 2] = int(clamp(_sp[s], 0.0, 1.0) * 255.0)
			var cold: float = clamp((4.0 - _smin[s]) / 8.0, 0.0, 1.0)
			cold = maxf(cold, clamp(_ssnow[s] * 3.0, 0.0, 1.0))
			bytes[bi + 3] = int(cold * 255.0)
		_imgs[f].set_data(res, res, false, Image.FORMAT_RGBA8, bytes)
	if _tex == null:
		_tex = Texture2DArray.new()
		_tex.create_from_images(_imgs)
	else:
		for f in range(6):
			_tex.update_layer(_imgs[f], f)
