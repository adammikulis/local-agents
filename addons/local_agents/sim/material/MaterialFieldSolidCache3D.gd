class_name LAMaterialFieldSolidCache3D
extends RefCounted

## Disk cache (user://, outside the tracked tree) for the field's solid mask, a pure function of the terrain
## generator's inputs and the grid.
##
## The key hashes every generator option, the grid geometry, and the source of BOTH scripts that decide the
## SDF — the terrain service and the sphere generator. A key that omits an input hands back the previous
## planet's mask without saying so.
##
## A hit is also spot-checked against the live terrain at SPOT_CELLS scattered cells. Those queries force
## generation of only the blocks they touch. Any disagreement discards the cache and does the full sample.

const DIR: String = "user://la_solid_cache"
const SPOT_CELLS: int = 256
const GENERATOR_SRC: PackedStringArray = [
	"res://addons/local_agents/sim/terrain/VoxelTerrainService.gd",
	"res://addons/local_agents/sim/sphere/SpherePlanetGenerator.gd",
]


## Hash of everything the mask depends on. `opts` is the generator options the terrain was built from
## (LAVoxelTerrainService.generator_options()). Returns "" when a generator source cannot be read — no key,
## no cache, rather than a key that does not cover the generator.
static func key(opts: Dictionary, cell_count: int, depth: int, core_radius: float, cell_size: float,
		origin: Vector3) -> String:
	var parts: PackedStringArray = PackedStringArray()
	var names: Array = opts.keys()
	names.sort()
	for k in names:
		# view_distance changes how much terrain is streamed, never what the SDF says at a point.
		if String(k) == "view_distance":
			continue
		parts.append("%s=%s" % [String(k), str(opts[k])])
	parts.append("cells=%d" % cell_count)
	parts.append("depth=%d" % depth)
	parts.append("core=%.6f" % core_radius)
	parts.append("cell=%.6f" % cell_size)
	parts.append("origin=%.4f,%.4f,%.4f" % [origin.x, origin.y, origin.z])
	for src_path in GENERATOR_SRC:
		var src: FileAccess = FileAccess.open(src_path, FileAccess.READ)
		if src == null:
			return ""
		parts.append("%s=%s" % [src_path,
				src.get_buffer(src.get_length()).get_string_from_utf8().sha256_text()])
	return "\n".join(parts).sha256_text()


static func _path(k: String) -> String:
	return "%s/%s.bin" % [DIR, k]


## Returns the cached mask, or an empty array on a miss or a failed spot-check.
static func load_mask(k: String, cell_count: int, field) -> PackedByteArray:
	if k == "":
		return PackedByteArray()
	var f: FileAccess = FileAccess.open(_path(k), FileAccess.READ)
	if f == null:
		return PackedByteArray()
	if int(f.get_length()) != cell_count:
		return PackedByteArray()
	var data: PackedByteArray = f.get_buffer(cell_count)
	if data.size() != cell_count:
		return PackedByteArray()
	if not _spot_check(data, cell_count, field):
		push_warning("LAMaterialFieldSolidCache3D: spot-check FAILED — cache discarded, resampling.")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_path(k)))
		return PackedByteArray()
	return data


## Compare SPOT_CELLS scattered cells against the live terrain. Deterministic stride so a failure reproduces.
static func _spot_check(data: PackedByteArray, cell_count: int, field) -> bool:
	if field == null or field._terrain == null:
		return false
	var stride: int = maxi(1, cell_count / SPOT_CELLS)
	var c: int = 0
	while c < cell_count:
		var want: int = 1 if field._terrain.is_solid(field.cell_world_pos_linear(c)) else 0
		if int(data[c]) != want:
			return false
		c += stride
	return true


static func save_mask(k: String, mask: PackedByteArray) -> void:
	if k == "":
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	var f: FileAccess = FileAccess.open(_path(k), FileAccess.WRITE)
	if f != null:
		f.store_buffer(mask)
