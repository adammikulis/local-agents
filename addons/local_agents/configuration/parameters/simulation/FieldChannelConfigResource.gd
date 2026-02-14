extends Resource
class_name LocalAgentsFieldChannelConfigResource

@export var schema_version: int = 1
@export var channel_id: String = ""
@export var storage_type: String = "float32"
@export var component_count: int = 1
@export var default_value: float = 0.0
@export var clamp_min: float = -1000000.0
@export var clamp_max: float = 1000000.0
@export var metadata: Dictionary = {}

func to_dict() -> Dictionary:
	return {
		"schema_version": schema_version,
		"channel_id": channel_id,
		"storage_type": storage_type,
		"component_count": component_count,
		"default_value": default_value,
		"clamp_min": clamp_min,
		"clamp_max": clamp_max,
		"metadata": metadata.duplicate(true),
	}

func from_dict(values: Dictionary) -> void:
	schema_version = int(values.get("schema_version", schema_version))
	channel_id = String(values.get("channel_id", channel_id)).strip_edges()
	if channel_id == "":
		channel_id = "unnamed_channel"
	storage_type = String(values.get("storage_type", storage_type)).strip_edges().to_lower()
	if storage_type == "":
		storage_type = "float32"
	component_count = clampi(int(values.get("component_count", component_count)), 1, 4)
	default_value = float(values.get("default_value", default_value))
	clamp_min = float(values.get("clamp_min", clamp_min))
	clamp_max = float(values.get("clamp_max", clamp_max))
	if clamp_max < clamp_min:
		var swap_min := clamp_max
		clamp_max = clamp_min
		clamp_min = swap_min
	default_value = clampf(default_value, clamp_min, clamp_max)
	var metadata_variant = values.get("metadata", {})
	if metadata_variant is Dictionary:
		metadata = _normalize_metadata(metadata_variant as Dictionary)
	else:
		metadata = {}

func _normalize_metadata(metadata_variant: Dictionary) -> Dictionary:
	var normalized: Dictionary = metadata_variant.duplicate(true)
	var unit := String(normalized.get("unit", String())).strip_edges()
	if unit.is_empty():
		unit = String(normalized.get("units", String())).strip_edges()
	normalized.erase("units")
	if unit != "":
		normalized["unit"] = unit

	var normalized_range := normalized.get("range", null)
	if normalized_range is Dictionary:
		var range_dict = normalized_range.duplicate(true)
		if range_dict.has("min") and range_dict.has("max"):
			var raw_min := range_dict.get("min")
			var raw_max := range_dict.get("max")
			if _is_finite_number(raw_min) and _is_finite_number(raw_max):
				range_dict["min"] = float(raw_min)
				range_dict["max"] = float(raw_max)
				normalized["range"] = range_dict
			else:
				normalized.erase("range")
		else:
			normalized.erase("range")
	return normalized

func _is_finite_number(value) -> bool:
	if value is int:
		return is_finite(float(value))
	if value is float:
		return is_finite(value)
	return false
