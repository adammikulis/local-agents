extends SceneTree

## The bake store's bound, from outside a run, on a scratch directory of its own. Five entries are written
## unbounded, the oldest is read back (a hit), a sixth is written under a bound that holds four and a half:
## the two least recently used go, never the one read. Then a bound of one byte: only the entry just
## written is left.

const ENTRY_BYTES: int = 65536
const UNBOUNDED: int = 1 << 40


func _init() -> void:
	var dir: String = "user://la_evict_probe_%d" % OS.get_process_id()
	for i in 5:
		_save(dir, i, UNBOUNDED)
	var held: Dictionary = LAFieldStateCache.load_from(dir, _key(0))
	var entry: int = _size(dir, 0)
	OS.delay_msec(30)
	var removed: int = _save(dir, 5, entry * 4 + entry / 2)
	var after_bound: PackedStringArray = _listing(dir)
	var bytes: int = 0
	for name in after_bound:
		bytes += _size_of(dir, name)
	OS.delay_msec(30)
	var removed_floor: int = _save(dir, 6, 1)
	var after_floor: PackedStringArray = _listing(dir)
	_remove_all(dir)
	print("EVICT_PROBE=", JSON.stringify({
		"entry_bytes": entry, "hit": not held.is_empty(),
		"removed": removed, "left": Array(after_bound), "left_bytes": bytes, "bound": entry * 4 + entry / 2,
		"removed_floor": removed_floor, "left_floor": Array(after_floor),
		"declared": LAFieldStateCache.declared_bound()}))
	quit(0)


func _key(i: int) -> String:
	return "k%d" % i


func _save(dir: String, i: int, bound: int) -> int:
	OS.delay_msec(30)
	var data: PackedByteArray = PackedByteArray()
	data.resize(ENTRY_BYTES)
	data.fill(i + 1)
	return LAFieldStateCache.save_into(dir, _key(i), {"snapshot": data}, bound)


func _size(dir: String, i: int) -> int:
	return _size_of(dir, _key(i) + ".bin")


func _size_of(dir: String, name: String) -> int:
	var f: FileAccess = FileAccess.open("%s/%s" % [dir, name], FileAccess.READ)
	return 0 if f == null else f.get_length()


func _listing(dir: String) -> PackedStringArray:
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return PackedStringArray()
	var names: PackedStringArray = d.get_files()
	names.sort()
	return names


func _remove_all(dir: String) -> void:
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return
	for name in d.get_files():
		d.remove(name)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))
