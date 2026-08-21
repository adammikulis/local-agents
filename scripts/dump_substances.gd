extends SceneTree

## THE SUBSTANCE AUTHORITY, AS BUILT. Prints every SCALAR property of LASubstances.table() as
## LASUB<TAB>LASubstances.<id>.<property><TAB>value, so a kernel copy of a material property binds to the
## table the simulation actually runs on rather than to a text parse of its source. Zero rows must FAIL.

func _init() -> void:
	var t: Dictionary = LASubstances.table()
	var rows: int = 0
	for id in t:
		var s: Dictionary = t[id]
		for k in s:
			var v: Variant = s[k]
			if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
				continue
			print("LASUB\tLASubstances.%s.%s\t%s" % [String(id), String(k), str(float(v))])
			rows += 1
	print("SUBSTANCE_DUMP_ROWS=%d" % rows)
	quit(0 if rows > 0 else 2)
