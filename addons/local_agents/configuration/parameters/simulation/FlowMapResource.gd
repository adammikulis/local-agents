extends Resource
class_name LocalAgentsFlowMapResource

@export var schema_version: int = 1
@export var width: int = 0
@export var height: int = 0
@export var max_flow: float = 0.0
@export var rows: Array = []
@export var row_index: Dictionary = {}

func to_dict() -> Dictionary:
	return {
		"schema_version": schema_version,
		"width": width,
		"height": height,
		"max_flow": max_flow,
		"rows": rows.duplicate(true),
		"row_index": row_index.duplicate(true),
	}

func from_dict(values: Dictionary) -> void:
	schema_version = int(values.get("schema_version", schema_version))
	width = maxi(0, int(values.get("width", width)))
	height = maxi(0, int(values.get("height", height)))
	max_flow = maxf(0.0, float(values.get("max_flow", max_flow)))
	var rows_variant = values.get("rows", [])
	rows = rows_variant.duplicate(true) if rows_variant is Array else []
	var index_variant = values.get("row_index", {})
	row_index = index_variant.duplicate(true) if index_variant is Dictionary else {}
