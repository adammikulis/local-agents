extends Resource
class_name LocalAgentsFieldRegistryConfigResource

const FieldChannelConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FieldChannelConfigResource.gd")

@export var schema_version: int = 1
@export var registry_id: String = "default_registry"
@export var map_width: int = 24
@export var map_height: int = 24
@export var voxel_world_height: int = 36
@export var channels: Array[LocalAgentsFieldChannelConfigResource] = []

func ensure_defaults() -> void:
	if not channels.is_empty():
		return
	channels = [
		_make_channel("temperature"),
		_make_channel("humidity"),
		_make_channel("surface_water"),
		_make_channel("flow_strength"),
		_make_channel("erosion_potential"),
		_make_channel("solar_exposure"),
	]

func to_dict() -> Dictionary:
	ensure_defaults()
	var channel_rows: Array = []
	for channel in channels:
		if channel == null:
			continue
		channel_rows.append(channel.to_dict())
	return {
		"schema_version": schema_version,
		"registry_id": registry_id,
		"map_width": map_width,
		"map_height": map_height,
		"voxel_world_height": voxel_world_height,
		"channels": channel_rows,
	}

func from_dict(values: Dictionary) -> void:
	schema_version = int(values.get("schema_version", schema_version))
	registry_id = String(values.get("registry_id", registry_id)).strip_edges()
	if registry_id == "":
		registry_id = "default_registry"
	map_width = maxi(1, int(values.get("map_width", map_width)))
	map_height = maxi(1, int(values.get("map_height", map_height)))
	voxel_world_height = maxi(1, int(values.get("voxel_world_height", voxel_world_height)))
	channels.clear()
	var channel_rows_variant = values.get("channels", [])
	if channel_rows_variant is Array:
		for row_variant in channel_rows_variant:
			if row_variant == null:
				continue
			if row_variant is LocalAgentsFieldChannelConfigResource:
				channels.append(row_variant)
				continue
			if row_variant is Dictionary:
				var row := FieldChannelConfigResourceScript.new()
				row.from_dict(row_variant as Dictionary)
				channels.append(row)
	ensure_defaults()

func _make_channel(channel_id_value: String) -> LocalAgentsFieldChannelConfigResource:
	var channel := FieldChannelConfigResourceScript.new()
	channel.channel_id = channel_id_value
	return channel
