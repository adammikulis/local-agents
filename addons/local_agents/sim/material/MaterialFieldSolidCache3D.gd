class_name LAMaterialFieldSolidCache3D
extends RefCounted

## Caches the field's solid mask, which is a pure function of the terrain generator's inputs and the grid.
## Sampling it costs ~0.36 s of GDScript, but WAITING for the terrain that answers those queries costs ~3.3 s,
## and a cache hit skips both.
##
## STALENESS IS DETECTED, NOT ASSUMED. The key is a hash of every generator option, the grid geometry and the
## generator script's own source, so any change to the world's definition misses. On top of that a hit is
## SPOT-CHECKED against the live terrain at SPOT_CELLS scattered cells before it is trusted — those queries
## force generation of only the blocks they touch, so the check is cheap while a whole-planet generation is
## not. Any disagreement discards the cache and does the full sample.
##
## A cache that can hand back the wrong planet without saying so would be the same defect class as a gauge
## that cannot report its failure case.

const DIR: String = "user://la_solid_cache"
const SPOT_CELLS: int = 256
const GENERATOR_SRC: String = "res://addons/local_agents/sim/terrain/VoxelTerrainService.gd"


## Hash of everything the mask depends on. `opts` is the dictionary handed to PlanetBody.setup().
static func key(opts: Dictionary, cell_count: int, depth: int, core_radius: float,
		shell_dr: PackedFloat32Array, origin: Vector3) -> String:
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
	for r in shell_dr.size():
		parts.append("dr%d=%.6f" % [r, shell_dr[r]])
	parts.append("origin=%.4f,%.4f,%.4f" % [origin.x, origin.y, origin.z])
	var src: FileAccess = FileAccess.open(GENERATOR_SRC, FileAccess.READ)
	if src != null:
		parts.append("gen=%s" % src.get_buffer(src.get_length()).get_string_from_utf8().sha256_text())
	return "\n".join(parts).sha256_text()


static func _path(k: String) -> String:
	return "%s/%s.bin" % [DIR, k]


## Returns the cached mask, or an empty array on a miss or a failed spot-check.
static func load_mask(k: String, cell_count: int, field) -> PackedByteArray:
	var f: FileAccess = FileAccess.open(_path(k), FileAccess.READ)
	if f == null:
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
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	var f: FileAccess = FileAccess.open(_path(k), FileAccess.WRITE)
	if f != null:
		f.store_buffer(mask)
