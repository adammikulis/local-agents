extends SceneTree

## The pure-function store, from outside a run. `--clear` empties it, `--read` prints what the seed's
## solved body comes out as and how many answers came off disk, `--corrupt` changes the stored planet seed.

var STORE: String = OS.get_environment("LA_PURE_CACHE_DIR") if OS.get_environment("LA_PURE_CACHE_DIR") != "" else "user://la_pure_cache"


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var mode: String = args[0] if args.size() > 0 else ""
	if mode == "--clear":
		LAFieldStateCache.pure_clear()
		print("PURE_PROBE={\"cleared\":true}")
		quit(0)
	elif mode == "--read":
		_read()
	elif mode == "--corrupt":
		_corrupt()
	else:
		printerr("pure_cache_probe: expected --clear, --read or --corrupt.")
		quit(2)


func _bits(values: PackedFloat64Array) -> String:
	return values.to_byte_array().hex_encode()


func _read() -> void:
	var r_m: float = LABodySeeds.seed_radius_m("planet")
	var t_c: float = LABodySeeds.surface_temp_c()
	var depth: PackedFloat32Array = PackedFloat32Array([0.0, 1000.0, 20000.0, 150000.0])
	var edge: PackedFloat32Array = PackedFloat32Array([10.0, 10.0, 10.0, 10.0])
	var geotherm: PackedFloat32Array = LAPlanetComposition.geotherm_c_cells(r_m, t_c, depth, edge)
	var solved: PackedFloat64Array = PackedFloat64Array([t_c, LABodySeeds.surface_pressure_pa(), r_m,
		LABodySeeds.seed_radius_m("moon")])
	for v in geotherm:
		solved.append(v)
	print("PURE_PROBE=", JSON.stringify({"hits": LAFieldStateCache.pure_hits(), "values": _bits(solved),
		"n": solved.size()}))
	quit(0)


## The planet seed is the entry holding three doubles; its temperature is moved.
func _corrupt() -> void:
	var dir: DirAccess = DirAccess.open(STORE)
	if dir == null:
		printerr("pure_cache_probe: no store at %s." % STORE)
		quit(2)
		return
	var changed: int = 0
	for name in dir.get_files():
		var path: String = "%s/%s" % [STORE, name]
		var f: FileAccess = FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var held: Variant = f.get_var()
		f.close()
		if not (held is Dictionary):
			continue
		var out: PackedFloat64Array = (held as Dictionary).get("out", PackedFloat64Array())
		if out.size() != 3:
			continue
		out[0] += 1.0
		(held as Dictionary)["out"] = out
		var w: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		w.store_var(held)
		w.close()
		changed += 1
	print("PURE_PROBE={\"corrupted\":%d}" % changed)
	quit(0 if changed == 1 else 2)
