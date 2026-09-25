extends SceneTree

## The bake store, from outside a run, over the seeded bakes the last argument's LA_SEAL_KEY wrote: every
## lane shares the store. `--clear <key>` removes them so an arm is a guaranteed miss; `--corrupt <channel>
## <key>` scales one channel of the one such LAFieldSnapshot, which is the positive control every identity
## gate needs: a comparison that cannot see a changed channel is not a comparison.

const STATE_DIR: String = "user://la_field_cache"


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var mode: String = args[0] if args.size() > 0 else ""
	var channel: String = args[1] if args.size() > 2 else "h2o"
	var key: String = args[args.size() - 1] if args.size() > 1 else ""
	var dir_path: String = STATE_DIR
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	var files: PackedStringArray = _bins(dir_path, key)
	if key == "":
		printerr("seal_cache_probe: no LA_SEAL_KEY named, so no bake is this caller's.")
		quit(2)
		return
	if mode == "--clear":
		for f in files:
			DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [dir_path, f]))
		print("SEAL_PROBE={\"cleared\":%d}" % files.size())
		quit(0)
		return
	if mode != "--corrupt":
		printerr("seal_cache_probe: expected --clear <key> or --corrupt <channel> <key>.")
		quit(2)
		return
	# The store also holds the grid's own blob, so the seeded field is the entry carrying a snapshot.
	var path: String = ""
	var data: Dictionary = {}
	for name in files:
		var candidate: String = "%s/%s" % [dir_path, name]
		var g: FileAccess = FileAccess.open(candidate, FileAccess.READ)
		if g == null:
			continue
		var held: Variant = g.get_var()
		if held is Dictionary and (held as Dictionary).has("snapshot"):
			if path != "":
				printerr("seal_cache_probe: two seeded bakes in %s; the gate clears it first so one stands."
					% dir_path)
				quit(2)
				return
			path = candidate
			data = held
	if path == "":
		printerr("seal_cache_probe: no seeded bake in %s (%d file(s))." % [dir_path, files.size()])
		quit(2)
		return
	var snapshot: PackedByteArray = data.get("snapshot", PackedByteArray())
	var at: int = _channel_at(snapshot, channel)
	if at < 0:
		printerr("seal_cache_probe: the bake's snapshot carries no '%s' channel." % channel)
		quit(2)
		return
	var cells: int = snapshot.decode_u32(8)
	for c in cells:
		var off: int = at + c * 4
		snapshot.encode_float(off, snapshot.decode_float(off) * 1.5 + 1.0)
	data["snapshot"] = snapshot
	var w: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if w == null:
		printerr("seal_cache_probe: cannot write %s" % path)
		quit(2)
		return
	w.store_var(data)
	print("SEAL_PROBE={\"corrupted\":\"%s\",\"cells\":%d}" % [channel, cells])
	quit(0)


## The store's seeded bakes whose LA_SEAL_KEY was `key`.
func _bins(dir_path: String, key: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var d: DirAccess = DirAccess.open(dir_path)
	if d == null:
		return out
	for name in d.get_files():
		if not String(name).ends_with(".bin"):
			continue
		var f: FileAccess = FileAccess.open("%s/%s" % [dir_path, name], FileAccess.READ)
		var held: Variant = f.get_var() if f != null else null
		if held is Dictionary and String((held as Dictionary).get("tree_key", "")) == key:
			out.append(String(name))
	return out


## Byte offset of a channel's cells inside LAFieldSnapshot's save layout, or -1 where it carries none.
func _channel_at(snapshot: PackedByteArray, channel: String) -> int:
	if snapshot.size() < 16 or snapshot.decode_u32(0) != 0x5346414C or snapshot.decode_u32(4) != 1:
		return -1
	var cells: int = snapshot.decode_u32(8)
	var count: int = snapshot.decode_u32(12)
	var at: int = 16
	at += 4 + snapshot.decode_u32(at)          # the world key
	var names: PackedStringArray = PackedStringArray()
	for i in count:
		var n: int = snapshot.decode_u32(at)
		names.append(snapshot.slice(at + 4, at + 4 + n).get_string_from_utf8())
		at += 4 + n
	var which: int = names.find(channel)
	return -1 if which < 0 else at + which * cells * 4

