class_name LAMaterialFieldRegolith3D
extends RefCounted

## LAMaterialFieldRegolith3D: the AQUIFER ROCK of LAMaterialField3D — which cells are permeable and how
## porous they are. There is no material-type table anywhere and there should never be one.

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


## Compute the permeability mask, the grain-size field and the initial water table. A cell is regolith when
## it is rock and fewer than REGOLITH_CELLS solid cells lie between it and open air UP the local vertical;
## that burial count is also its Athy compaction depth. No columns, no shell index.
func compute() -> void:
	if _f._grid == null or _f._solid.size() != _f._cell_count:
		return
	var cell_count: int = _f._cell_count
	_f._regolith = PackedByteArray()
	_f._regolith.resize(cell_count)                        # 0 = bedrock/void, 1 = permeable regolith
	_f._grain = PackedFloat32Array()
	_f._grain.resize(cell_count)                           # representative grain diameter, metres
	if _f._soil.size() != cell_count:
		_f._soil = PackedFloat32Array()
		_f._soil.resize(cell_count)
	var sea_r: float = _f.sea_radius()
	# The elevation band the grain-size gradient is read over: from the sea shell up to the highest ground
	# this planet actually has, so a flatter or steeper world still spans the same range of materials.
	var burial: PackedInt32Array = PackedInt32Array()
	burial.resize(cell_count)
	var highest: float = sea_r
	for c in cell_count:
		burial[c] = -1
		if _f._solid[c] == 0:
			continue
		burial[c] = LAFieldGeometry.burial_steps(_f, c, REGOLITH_CELLS)
		if burial[c] == 0:
			highest = maxf(highest, LAFieldGeometry.radius_of(_f, c))
	var relief: float = maxf(highest - sea_r, _f._grid.cell_size)

	for c in cell_count:
		var shells: int = burial[c]
		if shells < 0:
			continue                                      # void, or buried deeper than the aquifer band
		# Basins and sea floor get valley-fill alluvium, summits get residual saprolite.
		var height: float = clampf((LAFieldGeometry.radius_of(_f, c) - sea_r) / relief, 0.0, 1.0)
		_f._regolith[c] = 1
		_f._grain[c] = LAPhysical.GRAIN_D_LOWLAND_M * pow(
			LAPhysical.GRAIN_D_UPLAND_M / LAPhysical.GRAIN_D_LOWLAND_M, height)
		_f._soil[c] = porosity_at(shells) * INITIAL_TABLE_FRAC   # prime the water table
