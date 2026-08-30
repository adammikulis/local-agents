class_name LAMaterialFieldCache3D
extends RefCounted

const GENERATOR_SRC: PackedStringArray = [
	"res://addons/local_agents/sim/terrain/VoxelTerrainService.gd",
	"res://addons/local_agents/sim/terrain/SpherePlanetGenerator.gd",
]


static func key(opts: Dictionary, grid: LAVoxelGrid) -> String:
	return LAFieldStateCache.mask_key(opts, grid.nx, grid.ny, grid.nz, grid.cell_size, grid.origin,
			GENERATOR_SRC)


## The cached fractions and depths, or an empty dictionary on a miss or a failed spot-check of the mask.
static func load_fractions(k: String, cell_count: int) -> Dictionary:
	var data: Dictionary = LAFieldStateCache.load_blob(k)
	var rock: PackedFloat32Array = data.get("rock_fraction", PackedFloat32Array())
	var whole: bool = rock.size() == cell_count and data.get("ground_d", PackedFloat32Array()).size() == cell_count
	return data if whole else {}
