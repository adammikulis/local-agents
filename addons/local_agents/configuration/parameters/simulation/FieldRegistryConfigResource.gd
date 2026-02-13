extends Resource
class_name LocalAgentsFieldRegistryConfigResource

const FieldChannelConfigResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FieldChannelConfigResource.gd")

const _CANONICAL_FIELD_CHANNEL_DESCRIPTORS: Array[Dictionary] = [
	{
		"channel_id": "mass_density",
		"default_value": 1.0,
		"clamp_min": 0.0,
		"clamp_max": 1000000.0,
		"metadata": {"unit": "kg/m^3", "range": {"min": 0.0, "max": 1000000.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "momentum_x",
		"default_value": 0.0,
		"clamp_min": -1000000.0,
		"clamp_max": 1000000.0,
		"metadata": {"unit": "kg*m/s", "range": {"min": -1000000.0, "max": 1000000.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "momentum_y",
		"default_value": 0.0,
		"clamp_min": -1000000.0,
		"clamp_max": 1000000.0,
		"metadata": {"unit": "kg*m/s", "range": {"min": -1000000.0, "max": 1000000.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "momentum_z",
		"default_value": 0.0,
		"clamp_min": -1000000.0,
		"clamp_max": 1000000.0,
		"metadata": {"unit": "kg*m/s", "range": {"min": -1000000.0, "max": 1000000.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "pressure",
		"default_value": 1.0,
		"clamp_min": 0.0,
		"clamp_max": 1000000000.0,
		"metadata": {"unit": "Pa", "range": {"min": 0.0, "max": 1000000000.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "temperature",
		"default_value": 293.15,
		"clamp_min": 1.0,
		"clamp_max": 1000000.0,
		"metadata": {"unit": "K", "range": {"min": 1.0, "max": 1000000.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "internal_energy",
		"default_value": 0.0,
		"clamp_min": 0.0,
		"clamp_max": 1000000.0,
		"metadata": {"unit": "J/kg", "range": {"min": 0.0, "max": 1000000.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "phase_fraction_solid",
		"default_value": 0.0,
		"clamp_min": 0.0,
		"clamp_max": 1.0,
		"metadata": {"unit": "fraction", "range": {"min": 0.0, "max": 1.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "phase_fraction_liquid",
		"default_value": 0.0,
		"clamp_min": 0.0,
		"clamp_max": 1.0,
		"metadata": {"unit": "fraction", "range": {"min": 0.0, "max": 1.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "phase_fraction_gas",
		"default_value": 0.0,
		"clamp_min": 0.0,
		"clamp_max": 1.0,
		"metadata": {"unit": "fraction", "range": {"min": 0.0, "max": 1.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "porosity",
		"default_value": 0.25,
		"clamp_min": 0.0,
		"clamp_max": 1.0,
		"metadata": {"unit": "fraction", "range": {"min": 0.0, "max": 1.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "permeability",
		"default_value": 1.0,
		"clamp_min": 0.0,
		"clamp_max": 1000000.0,
		"metadata": {"unit": "m^2", "range": {"min": 0.0, "max": 1000000.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "cohesion",
		"default_value": 0.5,
		"clamp_min": 0.0,
		"clamp_max": 1.0,
		"metadata": {"unit": "dimensionless", "range": {"min": 0.0, "max": 1.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "friction_static",
		"default_value": 0.6,
		"clamp_min": 0.0,
		"clamp_max": 10.0,
		"metadata": {"unit": "dimensionless", "range": {"min": 0.0, "max": 10.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "friction_dynamic",
		"default_value": 0.4,
		"clamp_min": 0.0,
		"clamp_max": 10.0,
		"metadata": {"unit": "dimensionless", "range": {"min": 0.0, "max": 10.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "yield_strength",
		"default_value": 1.0,
		"clamp_min": 0.0,
		"clamp_max": 1.0e8,
		"metadata": {"unit": "Pa", "range": {"min": 0.0, "max": 1.0e8}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "damage",
		"default_value": 0.0,
		"clamp_min": 0.0,
		"clamp_max": 1.0,
		"metadata": {"unit": "dimensionless", "range": {"min": 0.0, "max": 1.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "fuel",
		"default_value": 0.0,
		"clamp_min": 0.0,
		"clamp_max": 1.0,
		"metadata": {"unit": "fraction", "range": {"min": 0.0, "max": 1.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "oxidizer",
		"default_value": 0.21,
		"clamp_min": 0.0,
		"clamp_max": 1.0,
		"metadata": {"unit": "fraction", "range": {"min": 0.0, "max": 1.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "reaction_progress",
		"default_value": 0.0,
		"clamp_min": 0.0,
		"clamp_max": 1.0,
		"metadata": {"unit": "dimensionless", "range": {"min": 0.0, "max": 1.0}, "strict": true, "canonical": true}
	},
	{
		"channel_id": "latent_energy_reservoir",
		"default_value": 0.0,
		"clamp_min": 0.0,
		"clamp_max": 1.0e9,
		"metadata": {"unit": "J/kg", "range": {"min": 0.0, "max": 1.0e9}, "strict": true, "canonical": true}
	},
]

@export var schema_version: int = 1
@export var registry_id: String = "default_registry"
@export var map_width: int = 24
@export var map_height: int = 24
@export var voxel_world_height: int = 36
@export var channels: Array[Resource] = []

func ensure_defaults() -> void:
	if not channels.is_empty():
		return
	channels = []
	for descriptor_variant in _CANONICAL_FIELD_CHANNEL_DESCRIPTORS:
		if descriptor_variant is Dictionary:
			channels.append(_make_channel_from_descriptor(descriptor_variant as Dictionary))

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
			if row_variant is Resource and row_variant.get_script() == FieldChannelConfigResourceScript:
				channels.append(row_variant)
				continue
			if row_variant is Dictionary:
				var row := FieldChannelConfigResourceScript.new()
				row.from_dict(row_variant as Dictionary)
				channels.append(row)
	ensure_defaults()

func _make_channel_from_descriptor(descriptor: Dictionary) -> Resource:
	var channel := FieldChannelConfigResourceScript.new()
	if descriptor.is_empty():
		return channel
	channel.from_dict(descriptor.duplicate(true))
	return channel

func _make_channel(channel_id_value: String) -> Resource:
	var channel := FieldChannelConfigResourceScript.new()
	channel.channel_id = channel_id_value
	return channel
