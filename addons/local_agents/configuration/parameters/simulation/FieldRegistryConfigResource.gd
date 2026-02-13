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
		validate_canonical_channel_contracts(true)
		return
	channels = []
	for descriptor_variant in _CANONICAL_FIELD_CHANNEL_DESCRIPTORS:
		if descriptor_variant is Dictionary:
			channels.append(_make_channel_from_descriptor(descriptor_variant as Dictionary))
	validate_canonical_channel_contracts(true)

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

func validate_canonical_channel_contracts(enforce: bool = true) -> Dictionary:
	var errors: Array = []
	var canonical_channels: Dictionary = _index_channels_by_id()
	for descriptor_variant in _CANONICAL_FIELD_CHANNEL_DESCRIPTORS:
		if not (descriptor_variant is Dictionary):
			continue
		var descriptor := descriptor_variant as Dictionary
		var channel_id := String(descriptor.get("channel_id", ""))
		if channel_id.is_empty():
			continue

		var channel_variant: Variant = canonical_channels.get(channel_id, null)
		if not (channel_variant is Resource):
			if enforce:
				var rebuilt := _make_channel_from_descriptor(descriptor)
				channels.append(rebuilt)
				canonical_channels[channel_id] = rebuilt
				errors.append("Missing canonical channel '%s'; added from descriptor" % channel_id)
			else:
				errors.append("Missing canonical channel '%s'" % channel_id)
			continue

		var channel := channel_variant as Resource
		var metadata_variant = channel.get("metadata")
		if not (metadata_variant is Dictionary):
			if enforce:
				channel.set("metadata", (descriptor.get("metadata", {}).duplicate(true) if descriptor.get("metadata") is Dictionary else {}))
			errors.append("Canonical channel '%s' metadata is invalid or missing" % channel_id)
			continue

		var metadata := metadata_variant as Dictionary
		var metadata_mutated := false
		var expected_metadata_variant := descriptor.get("metadata", {})
		if expected_metadata_variant is Dictionary:
			var expected_metadata := expected_metadata_variant as Dictionary
			var expected_strict: bool = bool(expected_metadata.get("strict", true))
			if metadata.get("strict", false) != expected_strict:
				if enforce:
					metadata["strict"] = expected_strict
					metadata_mutated = true
				errors.append("Canonical channel '%s' metadata.strict expected %s" % [channel_id, expected_strict])

			var expected_unit := String(expected_metadata.get("unit", ""))
			var observed_unit := String(metadata.get("unit", ""))
			if observed_unit != expected_unit:
				if enforce:
					metadata["unit"] = expected_unit
					metadata_mutated = true
				errors.append("Canonical channel '%s' metadata.unit expected '%s'" % [channel_id, expected_unit])

			var expected_range_variant := expected_metadata.get("range", {})
			var observed_range_variant := metadata.get("range", {})
			if not _metadata_range_equals(observed_range_variant, expected_range_variant):
				if enforce:
					metadata["range"] = (expected_range_variant.duplicate(true) if expected_range_variant is Dictionary else {})
					metadata_mutated = true
				errors.append("Canonical channel '%s' metadata.range expected %s" % [channel_id, str(expected_range_variant)])

			if enforce:
				var expected_canonical: bool = bool(expected_metadata.get("canonical", true))
				if metadata.get("canonical", false) != expected_canonical:
					metadata["canonical"] = expected_canonical
					metadata_mutated = true
		else:
			if enforce:
				channel.set("metadata", descriptor.get("metadata", {}).duplicate(true))
			errors.append("Canonical channel '%s' metadata template is not a dictionary" % channel_id)

		if metadata_mutated and enforce:
			channel.set("metadata", metadata)
	return {
		"ok": errors.is_empty(),
		"errors": errors,
	}

func _index_channels_by_id() -> Dictionary:
	var by_id: Dictionary = {}
	for row_variant in channels:
		if not (row_variant is Resource):
			continue
		var row := row_variant as Resource
		var row_id := String(row.get("channel_id"))
		if row_id == "" or by_id.has(row_id):
			continue
		by_id[row_id] = row
	return by_id

func _metadata_range_equals(lhs_variant: Variant, rhs_variant: Variant) -> bool:
	if not (lhs_variant is Dictionary) or not (rhs_variant is Dictionary):
		return false
	var lhs := lhs_variant as Dictionary
	var rhs := rhs_variant as Dictionary
	if not lhs.has("min") or not lhs.has("max") or not rhs.has("min") or not rhs.has("max"):
		return false
	return is_equal_approx(float(lhs.get("min", 0.0)), float(rhs.get("min", 0.0))) and is_equal_approx(float(lhs.get("max", 0.0)), float(rhs.get("max", 0.0)))

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
