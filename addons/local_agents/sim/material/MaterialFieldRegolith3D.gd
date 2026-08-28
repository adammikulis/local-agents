class_name LAMaterialFieldRegolith3D
extends RefCounted

## Which cells are permeable regolith and how porous they are.

## Solid shells below the ground surface that are permeable.
const REGOLITH_CELLS: int = 4
var _f = null


func setup(field) -> void:
	_f = field


static func shell_metres() -> float:
	return LAPhysical.GROUNDWATER_CIRCULATION_M / float(REGOLITH_CELLS)


## Athy (1930) porosity at a burial depth of `shells` regolith cells below the surface.
static func porosity_at(shells: int) -> float:
	var z: float = (float(shells) + 0.5) * shell_metres()
	return LAPhysical.REGOLITH_SURFACE_POROSITY * exp(-z / LAPhysical.COMPACTION_LENGTH_M)


## The permeability mask, the grain-size field and the pore fraction, walked in the GDExtension. The
## water that stands in those pores is the body's own, and LAFieldHydrosphereSeed lays it.
func compute() -> void:
	LAFieldCellMass3D.regolith(_f, REGOLITH_CELLS)
