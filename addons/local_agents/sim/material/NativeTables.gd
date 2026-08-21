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


## One of LASubstances' phase tags. A native class constant is on ClassDB, not on the instance.
static func phase(name: StringName) -> int:
	return ClassDB.class_get_integer_constant(&"LASubstances", name)


## Elemental composition of the planet's reservoirs.
static func abundances() -> Object:
	return _handle(&"LAElementAbundances")


## The seeded mineralogy, derived from the abundances.
static func composition() -> Object:
	return _handle(&"LAPlanetComposition")


## Radiogenic heat and daughter accumulation.
static func decay() -> Object:
	return _handle(&"LARadiogenicDecay")


## The packed absorption-band table.
static func bands() -> Object:
	return _handle(&"LAAbsorptionBands")
