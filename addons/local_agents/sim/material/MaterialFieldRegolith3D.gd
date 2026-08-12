class_name LAMaterialFieldRegolith3D
extends RefCounted

## Which cells are permeable regolith and how porous they are.

## Solid shells below the ground surface that are permeable.
const REGOLITH_CELLS: int = 4
## Initial saturation of the regolith pore space.
const INITIAL_TABLE_FRAC: float = 0.5

var _f = null


func setup(field) -> void:
	_f = field


static func shell_metres() -> float:
	return LAPhysical.GROUNDWATER_CIRCULATION_M / float(REGOLITH_CELLS)


## Athy (1930) porosity at a burial depth of `shells` regolith cells below the surface.
static func porosity_at(shells: int) -> float:
	var z: float = (float(shells) + 0.5) * shell_metres()
	return LAPhysical.REGOLITH_SURFACE_POROSITY * exp(-z / LAPhysical.COMPACTION_LENGTH_M)


## Compute the permeability mask, the grain-size field and the initial water table.
func compute() -> void:
	if _f._grid == null or _f._solid.size() != _f._cell_count:
		return
	var cell_count: int = _f._cell_count
	_f._regolith = PackedByteArray()
	_f._regolith.resize(cell_count)                        # 0 = bedrock/void, 1 = permeable regolith
	_f._grain = PackedFloat32Array()
	_f._grain.resize(cell_count)                           # representative grain diameter, metres
	_f._porosity = PackedFloat32Array()
	_f._porosity.resize(cell_count)                        # Athy pore fraction, 0 outside the regolith band
	if _f._h2o.size() != cell_count:
		_f._h2o = PackedFloat32Array()
		_f._h2o.resize(cell_count)
	var sea_r: float = _f.sea_radius()
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
			continue
		var height: float = clampf((LAFieldGeometry.radius_of(_f, c) - sea_r) / relief, 0.0, 1.0)
		var phi: float = porosity_at(shells)
		_f._regolith[c] = 1
		_f._grain[c] = LAPhysical.GRAIN_D_LOWLAND_M * pow(
			LAPhysical.GRAIN_D_UPLAND_M / LAPhysical.GRAIN_D_LOWLAND_M, height)
		_f._porosity[c] = phi
		_f._h2o[c] = phi * INITIAL_TABLE_FRAC                    # prime the water table
