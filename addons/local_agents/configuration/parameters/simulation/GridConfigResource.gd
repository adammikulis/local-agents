extends Resource
class_name LocalAgentsGridConfigResource

@export var schema_version: int = 1
@export var grid_layout: String = "hex_pointy"
@export var half_extent: float = 10.0
@export var cell_size: float = 0.45

func to_dict() -> Dictionary:
	return {
		"schema_version": schema_version,
		"grid_layout": grid_layout,
		"half_extent": half_extent,
		"cell_size": cell_size,
	}

func from_dict(payload: Dictionary) -> void:
	schema_version = int(payload.get("schema_version", schema_version))
	grid_layout = String(payload.get("grid_layout", grid_layout))
	half_extent = maxf(1.0, float(payload.get("half_extent", half_extent)))
	cell_size = maxf(0.1, float(payload.get("cell_size", cell_size)))
