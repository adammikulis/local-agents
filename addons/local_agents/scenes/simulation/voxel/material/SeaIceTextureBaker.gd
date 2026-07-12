class_name LASeaIceTextureBaker
extends RefCounted

## Bakes the EMERGENT sea-ice signal into a 6-layer R8-in-RGBA8 Texture2DArray — one texel per SphereGrid
## surface column — the render bridge the ocean shell (VoxelWaterSphere.gdshader) samples so frozen sea reads
## WHITE from orbit (polar caps + winter sea ice) while open sea stays blue. Sea ice is NOT a new phenomenon
## with its own physics: it is simply the conserved `_snow` (frozen H₂O) channel that the generic freeze
## reaction (MaterialReactions3D R21: WATER → SNOW below FREEZE_TEMP) accumulates on cold STATIC-SEA surface
## cells, and thaws (R22) where the sea warms back up. This baker only READS that field and reduces it to a
## per-column 0..1 "sea frozen" value for the shader — no simulation, no special-case cap code.
##
## Per column c = s*depth + r: scan radially OUTWARD→in for the topmost STATIC-sea cell (the sea surface). Its
## `snow` depth, scaled + clamped, is the ice value. Land columns (a solid cell is hit before any sea) and open
## warm sea (no snow on the surface cell) bake to 0. ONE O(surf_count) reduction, folded into the sea-ice
## controller's throttled refresh. Cell layout + face packing MATCH CoverTextureBaker/BiomeTextureBaker so the
## shader's inverse-gnomonic face sample lands on the exact texel. (Explicit types only — no ':=' .)

const ICE_GAIN: float = 6.0        # snow-depth → ice coverage: a thin frozen skin (~0.17) already reads fully white
const SNOW_PRESENT: float = 0.01   # MUST match MaterialField3D.SNOW_PRESENT — dust-thin snow is not ice yet

var _res: int = 0
var _depth: int = 0
var _surf: int = 0

var _sice: PackedFloat32Array = PackedFloat32Array()    # per-column sea-ice coverage 0..1
var _imgs: Array = []
var _tex: Texture2DArray = null


func setup(grid: RefCounted) -> void:
	_res = grid.res
	_depth = grid.depth
	_surf = grid.surf_count
	_sice.resize(_surf)
	_imgs = []
	for f in range(6):
		_imgs.append(Image.create(_res, _res, false, Image.FORMAT_RGBA8))


func texture() -> Texture2DArray:
	return _tex


## Reduce the field's per-cell snow over each surface column into the sea-ice coverage, then pack the texture.
func bake(snow: PackedFloat32Array, solid: PackedByteArray, static_cells: PackedByteArray, cell_count: int) -> void:
	if _surf <= 0 or snow.size() != cell_count or static_cells.size() != cell_count:
		return
	_sice.fill(0.0)
	var depth: int = _depth
	for s in range(_surf):
		var base: int = s * depth
		# Scan OUTWARD shell → in for the topmost sea surface (first STATIC cell). Stop at solid ground first
		# (a land/mountain column that pokes above the sea has no sea surface → stays 0).
		for r in range(depth - 1, -1, -1):
			var c: int = base + r
			if solid[c] != 0:
				break                                    # hit land before any sea → dry column, no sea ice
			if static_cells[c] != 0:
				if snow[c] > SNOW_PRESENT:
					_sice[s] = clamp(snow[c] * ICE_GAIN, 0.0, 1.0)
				break                                    # topmost sea layer classified → done with this column
	_pack()


## Pack the per-column ice coverage into the R channel of the 6-layer RGBA8 texture. Face f, surface (i,j) ->
## pixel (x=i, y=j) — IDENTICAL mapping to CoverTextureBaker._pack so the shader recovers the texel exactly.
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
			var v: int = int(clamp(_sice[s], 0.0, 1.0) * 255.0)
			bytes[bi + 0] = v
			bytes[bi + 1] = 0
			bytes[bi + 2] = 0
			bytes[bi + 3] = 255
		_imgs[f].set_data(res, res, false, Image.FORMAT_RGBA8, bytes)
	if _tex == null:
		_tex = Texture2DArray.new()
		_tex.create_from_images(_imgs)
	else:
		for f in range(6):
			_tex.update_layer(_imgs[f], f)
