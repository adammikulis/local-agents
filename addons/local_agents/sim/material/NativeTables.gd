class_name LANativeTables
extends RefCounted

## The GDExtension's tables, reached by NAME rather than by identifier so the addon still parses in a
## library-only install with no built extension. One handle per class, made once.
static var _handles: Dictionary = {}


static func _handle(cls: StringName) -> Object:
	if not _handles.has(cls):
		_handles[cls] = ClassDB.instantiate(cls)
	return _handles[cls]


## The SSOT for matter.
static func subs() -> Object:
	return _handle(&"LASubstances")


## A cell's temperature from its enthalpy, over the substances it holds.
static func mixture() -> Object:
	return _handle(&"LAMixtureEnthalpy")


## One of LASubstances' phase tags. A native class constant is on ClassDB, not on the instance.
static func phase(name: StringName) -> int:
	return ClassDB.class_get_integer_constant(&"LASubstances", name)


## Elemental composition of the planet's reservoirs.
static func abundances() -> Object:
	return _handle(&"LAElementAbundances")


## The seeded mineralogy, derived from the abundances.
static func composition() -> Object:
	return _handle(&"LAPlanetComposition")


## What a body is given, and the seed-time serial walks over the field.
static func body_seeds() -> Object: return _handle(&"LABodySeeds")


static func lithostatic() -> Object: return _handle(&"LAFieldLithostaticSeed")


## The one walk from channel amounts to kilograms.
static func cell_mass() -> Object: return _handle(&"LAFieldCellMass3D")


## Radiogenic heat and daughter accumulation.
static func decay() -> Object:
	return _handle(&"LARadiogenicDecay")


## The packed absorption-band table.
static func bands() -> Object:
	return _handle(&"LAAbsorptionBands")
