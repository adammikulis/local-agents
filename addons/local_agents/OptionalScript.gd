class_name LAOptionalScript
extends RefCounted


# Resolves a script that may not be present, so a layer parses and runs when the tree holding the
# script is deleted. Caches the miss as well as the hit: `has(path)`, never a truthiness test.
static var _cache: Dictionary = {}


static func resolve(path: String) -> GDScript:
	if _cache.has(path):
		return _cache[path]
	var found: GDScript = null
	if ResourceLoader.exists(path):
		found = load(path) as GDScript
	_cache[path] = found
	return found
