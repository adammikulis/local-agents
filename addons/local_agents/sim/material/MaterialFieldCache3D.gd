class_name LAMaterialFieldCache3D
extends RefCounted

## The spot-check over `LAFieldStateCache`'s solid mask, which is the one part of that cache that has to
## ask the live terrain. Everything else it does is serial file work and lives in the GDExtension.

const SPOT_CELLS: int = 256
const GENERATOR_SRC: PackedStringArray = [
	"res://addons/local_agents/sim/terrain/VoxelTerrainService.gd",
	"res://addons/local_agents/sim/terrain/SpherePlanetGenerator.gd",
]


static func key(opts: Dictionary, grid: LAVoxelGrid) -> String:
	return LAFieldStateCache.mask_key(opts, grid.nx, grid.ny, grid.nz, grid.cell_size, grid.origin,
			GENERATOR_SRC)


## The cached rock fraction, or an empty array on a miss or a failed spot-check of its mask.
static func load_fraction(k: String, cell_count: int, field) -> PackedFloat32Array:
	var data: PackedFloat32Array = LAFieldStateCache.load_blob(k).get("rock_fraction", PackedFloat32Array())
	if data.size() != cell_count or not _spot_check(LAPlanetComposition.solid_of(data), cell_count, field):
		return PackedFloat32Array()
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
