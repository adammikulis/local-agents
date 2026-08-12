class_name LAMaterialFieldRegolith3D
extends RefCounted

## LAMaterialFieldRegolith3D: the AQUIFER ROCK of LAMaterialField3D — which cells are permeable, how coarse
## conductivity of 4.05 m/s: twenty-six times the coarsest natural gravel, a thousand million times a silt.
## Kozeny-Carman. There is no material-type table anywhere and there should never be one — "sand" and "clay"
## cell's water CAPACITY, and it is the phi in Kozeny-Carman. A separate `SOIL_CAPACITY = 0.6` used to sit

## Rooting / aquifer band: the top REGOLITH_CELLS solid shells of each column are permeable; below is bedrock.
const REGOLITH_CELLS: int = 4
## Regolith starts half-saturated so springs flow from the start — a planet has an existing aquifer, which
## then self-maintains through rain and snowmelt recharge.
const INITIAL_TABLE_FRAC: float = 0.5

var _f = null                                            # back-reference to the owning LAMaterialField3D


func setup(field) -> void:
	_f = field


static func shell_metres() -> float:
	return LAPhysical.GROUNDWATER_CIRCULATION_M / float(REGOLITH_CELLS)


## Porosity at a burial depth of `shells` regolith cells below the ground surface (0 = the surface shell).
## Athy (1930) exponential compaction. This is BOTH the cell's saturated water capacity and the phi that
## Kozeny-Carman turns into permeability — because they are the same physical quantity.
static func porosity_at(shells: int) -> float:
	var z: float = (float(shells) + 0.5) * shell_metres()
	return LAPhysical.REGOLITH_SURFACE_POROSITY * exp(-z / LAPhysical.COMPACTION_LENGTH_M)


## Compute the permeability mask, the grain-size field and the initial water table in one column sweep.
## Grid columns are contiguous (cell = surf_col * depth + r, r = depth-1 outermost), so the ground surface of
## a column is simply its outermost solid shell.
func compute() -> void:
	if _f._sphere == null or _f._solid.size() != _f._cell_count:
		return
	var cell_count: int = _f._cell_count
	_f._regolith = PackedByteArray()
	_f._regolith.resize(cell_count)                        # 0 = bedrock/void, 1 = permeable regolith
	_f._grain = PackedFloat32Array()
	_f._grain.resize(cell_count)                           # representative grain diameter, metres
	if _f._soil.size() != cell_count:
		_f._soil = PackedFloat32Array()
		_f._soil.resize(cell_count)
	var surf_count: int = int(_f._sphere.surf_count)
	var depth: int = int(_f._sphere.depth)
	var mid: PackedFloat32Array = _f._sphere.shell_mid
	var sea_r: float = _f.sea_level
	# The elevation band the grain-size gradient is read over: from the sea shell up to the highest ground
	# this planet actually has. Derived from the terrain rather than assumed, so a flatter or steeper world
	# still spans the same range of materials.
	var highest: float = sea_r
	for s in range(surf_count):
		var base: int = s * depth
		for r in range(depth - 1, -1, -1):
			if _f._solid[base + r] != 0:
				var e: float = mid[r]
				if e > highest:
					highest = e
				break
	var relief: float = maxf(highest - sea_r, float(_f._sphere.cell_size))

	for s in range(surf_count):
		var base: int = s * depth
		var surf_r: int = -1
		for r in range(depth - 1, -1, -1):                # the outermost solid shell = the ground surface
			if _f._solid[base + r] != 0:
				surf_r = r
				break
		if surf_r < 0:
			continue                                      # an all-open column (deep ocean over no floor)
		# relief: basins and sea floor get valley-fill alluvium, summits get residual saprolite. Log, not
		var elev: float = mid[surf_r]
		var height: float = clampf((elev - sea_r) / relief, 0.0, 1.0)
		var d_grain: float = LAPhysical.GRAIN_D_LOWLAND_M * pow(
			LAPhysical.GRAIN_D_UPLAND_M / LAPhysical.GRAIN_D_LOWLAND_M, height)
		var lo: int = maxi(0, surf_r - REGOLITH_CELLS + 1)
		for r in range(lo, surf_r + 1):
			if _f._solid[base + r] == 0:
				continue
			var c: int = base + r
			_f._regolith[c] = 1
			_f._grain[c] = d_grain
			_f._soil[c] = porosity_at(surf_r - r) * INITIAL_TABLE_FRAC   # prime the water table
