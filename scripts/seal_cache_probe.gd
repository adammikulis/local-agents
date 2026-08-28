extends SceneTree

## The bake store, from outside a run. `--clear` empties it so an arm is a guaranteed miss; `--corrupt`
## scales one channel of the single file left there, which is the positive control every identity gate
## needs: a comparison that cannot see a changed channel is not a comparison.

const STATE_DIR: String = "user://la_field_cache"


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var mode: String = args[0] if args.size() > 0 else ""
	var channel: String = args[1] if args.size() > 1 else "h2o"
	var dir_path: String = STATE_DIR
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	var files: PackedStringArray = _bins(dir_path)
	if mode == "--clear":
		for f in files:
			DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [dir_path, f]))
		print("SEAL_PROBE={\"cleared\":%d}" % files.size())
		quit(0)
		return
	if mode != "--corrupt":
		printerr("seal_cache_probe: expected --clear or --corrupt <channel>.")
		quit(2)
		return
	if files.size() != 1:
		printerr("seal_cache_probe: %d bake file(s) in %s; the gate clears it first so exactly one stands."
			% [files.size(), dir_path])
		quit(2)
		return
	var path: String = "%s/%s" % [dir_path, files[0]]
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		printerr("seal_cache_probe: cannot read %s" % path)
		quit(2)
		return
	var raw: Variant = f.get_var()
	f = null
	if not (raw is Dictionary):
		printerr("seal_cache_probe: %s holds no dictionary." % path)
		quit(2)
		return
	var data: Dictionary = raw
	var channels: Dictionary = data.get("channels", {})
	if not channels.has(channel):
		printerr("seal_cache_probe: the bake carries no '%s' channel." % channel)
		quit(2)
		return
	var arr: PackedFloat32Array = channels[channel]
	for i in arr.size():
		arr[i] = arr[i] * 1.5 + 1.0
	channels[channel] = arr
	data["channels"] = channels
	var w: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if w == null:
		printerr("seal_cache_probe: cannot write %s" % path)
		quit(2)
		return
	w.store_var(data)
	print("SEAL_PROBE={\"corrupted\":\"%s\",\"cells\":%d}" % [channel, arr.size()])
	quit(0)


func _bins(dir_path: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var d: DirAccess = DirAccess.open(dir_path)
	if d == null:
		return out
	for name in d.get_files():
		if String(name).ends_with(".bin"):
			out.append(String(name))
	return out
