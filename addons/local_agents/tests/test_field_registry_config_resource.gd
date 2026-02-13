@tool
extends RefCounted

const FIELD_CHANNEL_SCRIPT_PATH := "res://addons/local_agents/configuration/parameters/simulation/FieldChannelConfigResource.gd"
const FIELD_REGISTRY_SCRIPT_PATH := "res://addons/local_agents/configuration/parameters/simulation/FieldRegistryConfigResource.gd"

const BOUNDED_RUNTIME_SCRIPT_PATH := "res://addons/local_agents/tests/run_runtime_tests_bounded.gd"
const TEMP_RESOURCE_PATH := "user://local_agents/tests/tmp_field_registry_config_resource.tres"
const CANONICAL_FIELD_DEFAULTS_BY_ID: Dictionary = {
	"mass_density": {"default_value": 1.0, "clamp_min": 0.0, "clamp_max": 1000000.0, "metadata": {"unit": "kg/m^3", "range": {"min": 0.0, "max": 1000000.0}, "strict": true, "canonical": true}},
	"momentum_x": {"default_value": 0.0, "clamp_min": -1000000.0, "clamp_max": 1000000.0, "metadata": {"unit": "kg*m/s", "range": {"min": -1000000.0, "max": 1000000.0}, "strict": true, "canonical": true}},
	"momentum_y": {"default_value": 0.0, "clamp_min": -1000000.0, "clamp_max": 1000000.0, "metadata": {"unit": "kg*m/s", "range": {"min": -1000000.0, "max": 1000000.0}, "strict": true, "canonical": true}},
	"momentum_z": {"default_value": 0.0, "clamp_min": -1000000.0, "clamp_max": 1000000.0, "metadata": {"unit": "kg*m/s", "range": {"min": -1000000.0, "max": 1000000.0}, "strict": true, "canonical": true}},
	"pressure": {"default_value": 1.0, "clamp_min": 0.0, "clamp_max": 1000000000.0, "metadata": {"unit": "Pa", "range": {"min": 0.0, "max": 1000000000.0}, "strict": true, "canonical": true}},
	"temperature": {"default_value": 293.15, "clamp_min": 1.0, "clamp_max": 1000000.0, "metadata": {"unit": "K", "range": {"min": 1.0, "max": 1000000.0}, "strict": true, "canonical": true}},
	"internal_energy": {"default_value": 0.0, "clamp_min": 0.0, "clamp_max": 1000000.0, "metadata": {"unit": "J/kg", "range": {"min": 0.0, "max": 1000000.0}, "strict": true, "canonical": true}},
	"phase_fraction_solid": {"default_value": 0.0, "clamp_min": 0.0, "clamp_max": 1.0, "metadata": {"unit": "fraction", "range": {"min": 0.0, "max": 1.0}, "strict": true, "canonical": true}},
	"phase_fraction_liquid": {"default_value": 0.0, "clamp_min": 0.0, "clamp_max": 1.0, "metadata": {"unit": "fraction", "range": {"min": 0.0, "max": 1.0}, "strict": true, "canonical": true}},
	"phase_fraction_gas": {"default_value": 0.0, "clamp_min": 0.0, "clamp_max": 1.0, "metadata": {"unit": "fraction", "range": {"min": 0.0, "max": 1.0}, "strict": true, "canonical": true}},
	"porosity": {"default_value": 0.25, "clamp_min": 0.0, "clamp_max": 1.0, "metadata": {"unit": "fraction", "range": {"min": 0.0, "max": 1.0}, "strict": true, "canonical": true}},
	"permeability": {"default_value": 1.0, "clamp_min": 0.0, "clamp_max": 1000000.0, "metadata": {"unit": "m^2", "range": {"min": 0.0, "max": 1000000.0}, "strict": true, "canonical": true}},
	"cohesion": {"default_value": 0.5, "clamp_min": 0.0, "clamp_max": 1.0, "metadata": {"unit": "dimensionless", "range": {"min": 0.0, "max": 1.0}, "strict": true, "canonical": true}},
	"friction_static": {"default_value": 0.6, "clamp_min": 0.0, "clamp_max": 10.0, "metadata": {"unit": "dimensionless", "range": {"min": 0.0, "max": 10.0}, "strict": true, "canonical": true}},
	"friction_dynamic": {"default_value": 0.4, "clamp_min": 0.0, "clamp_max": 10.0, "metadata": {"unit": "dimensionless", "range": {"min": 0.0, "max": 10.0}, "strict": true, "canonical": true}},
	"yield_strength": {"default_value": 1.0, "clamp_min": 0.0, "clamp_max": 1.0e8, "metadata": {"unit": "Pa", "range": {"min": 0.0, "max": 1.0e8}, "strict": true, "canonical": true}},
	"damage": {"default_value": 0.0, "clamp_min": 0.0, "clamp_max": 1.0, "metadata": {"unit": "dimensionless", "range": {"min": 0.0, "max": 1.0}, "strict": true, "canonical": true}},
	"fuel": {"default_value": 0.0, "clamp_min": 0.0, "clamp_max": 1.0, "metadata": {"unit": "fraction", "range": {"min": 0.0, "max": 1.0}, "strict": true, "canonical": true}},
	"oxidizer": {"default_value": 0.21, "clamp_min": 0.0, "clamp_max": 1.0, "metadata": {"unit": "fraction", "range": {"min": 0.0, "max": 1.0}, "strict": true, "canonical": true}},
	"reaction_progress": {"default_value": 0.0, "clamp_min": 0.0, "clamp_max": 1.0, "metadata": {"unit": "dimensionless", "range": {"min": 0.0, "max": 1.0}, "strict": true, "canonical": true}},
	"latent_energy_reservoir": {"default_value": 0.0, "clamp_min": 0.0, "clamp_max": 1.0e9, "metadata": {"unit": "J/kg", "range": {"min": 0.0, "max": 1.0e9}, "strict": true, "canonical": true}},
}

const CANONICAL_SHARED_FIELD_DEFAULTS: Dictionary = {
	"storage_type": "float32",
	"component_count": 1,
}

func run_test(_tree: SceneTree) -> bool:
	var ok := true
	ok = _test_channel_round_trip_and_normalization() and ok
	ok = _test_registry_defaults_and_serialization_contract() and ok
	ok = _test_validate_canonical_channel_contracts() and ok
	ok = _test_channel_resource_save_load_serialization() and ok
	ok = _test_bounded_runtime_timeout_defaults() and ok
	if ok:
		print("Field registry/channel resource tests passed")
	return ok

func _test_channel_round_trip_and_normalization() -> bool:
	var metadata_source := {"nested": {"value": 5}}
	var channel = _new_channel()
	if channel == null:
		return false
	channel.from_dict({
		"schema_version": 2,
		"channel_id": "   ",
		"storage_type": " FLOAT16 ",
		"component_count": 999,
		"default_value": 5000.0,
		"clamp_min": 10.0,
		"clamp_max": -3.0,
		"metadata": metadata_source,
	})

	var ok := true
	ok = _assert(channel.schema_version == 2, "Channel schema_version should deserialize") and ok
	ok = _assert(channel.channel_id == "unnamed_channel", "Blank channel_id should normalize to unnamed_channel") and ok
	ok = _assert(channel.storage_type == "float16", "storage_type should normalize to lowercase") and ok
	ok = _assert(channel.component_count == 4, "component_count should clamp to 4") and ok
	ok = _assert(is_equal_approx(channel.clamp_min, -3.0), "clamp_min should swap when min/max inverted") and ok
	ok = _assert(is_equal_approx(channel.clamp_max, 10.0), "clamp_max should swap when min/max inverted") and ok
	ok = _assert(is_equal_approx(channel.default_value, 10.0), "default_value should clamp into min/max bounds") and ok

	metadata_source["nested"]["value"] = 42
	var nested: Dictionary = channel.metadata.get("nested", {})
	ok = _assert(int((nested as Dictionary).get("value", -1)) == 5, "metadata should be deep-copied on from_dict") and ok

	var round_trip = _new_channel()
	if round_trip == null:
		return false
	round_trip.from_dict(channel.to_dict())
	ok = _assert(round_trip.channel_id == channel.channel_id, "channel_id should round-trip through to_dict/from_dict") and ok
	ok = _assert(round_trip.storage_type == channel.storage_type, "storage_type should round-trip through to_dict/from_dict") and ok
	ok = _assert(round_trip.component_count == channel.component_count, "component_count should round-trip through to_dict/from_dict") and ok
	return ok

func _test_registry_defaults_and_serialization_contract() -> bool:
	var registry = _new_registry()
	if registry == null:
		return false
	registry.ensure_defaults()
	var canonical_ids := _canonical_field_ids()

	var ok := true
	ok = _assert(registry.schema_version == 1, "Registry should default schema_version to 1") and ok
	ok = _assert(registry.registry_id == "default_registry", "Registry should default registry_id to default_registry") and ok
	ok = _assert(registry.map_width == 24, "Registry should default map_width to 24") and ok
	ok = _assert(registry.map_height == 24, "Registry should default map_height to 24") and ok
	ok = _assert(registry.voxel_world_height == 36, "Registry should default voxel_world_height to 36") and ok
	ok = _assert(_has_default_channels_in_any_order(registry.channels, canonical_ids), "Registry canonical channel IDs should match expected set") and ok
	ok = _assert(not registry.channels.is_empty(), "Registry should generate canonical channels via ensure_defaults") and ok

	for entry in registry.channels:
		if not (entry is Resource):
			ok = _assert(false, "Registry channels should always be resources") and ok
			continue
		var channel: Resource = entry
		var channel_id := String(channel.get("channel_id"))
		var expected_channel_variant: Variant = CANONICAL_FIELD_DEFAULTS_BY_ID.get(channel_id)
		ok = _assert(expected_channel_variant is Dictionary, "Canonical channel id %s should be recognized" % channel_id) and ok
		if not (expected_channel_variant is Dictionary):
			continue
		var expected_channel := expected_channel_variant as Dictionary
		ok = _assert(CANONICAL_SHARED_FIELD_DEFAULTS["storage_type"] == String(channel.storage_type), "Canonical channel %s should keep default storage_type" % channel_id) and ok
		ok = _assert(int(CANONICAL_SHARED_FIELD_DEFAULTS["component_count"]) == int(channel.component_count), "Canonical channel %s should keep default component_count" % channel_id) and ok
		var default_value_matches := is_equal_approx(float(channel.default_value), float(expected_channel.get("default_value", 0.0)))
		ok = _assert(default_value_matches, "Canonical channel %s should keep default default_value" % channel_id) and ok
		var clamp_min_matches := is_equal_approx(float(channel.clamp_min), float(expected_channel.get("clamp_min", 0.0)))
		ok = _assert(clamp_min_matches, "Canonical channel %s should keep default clamp_min" % channel_id) and ok
		var clamp_max_matches := is_equal_approx(float(channel.clamp_max), float(expected_channel.get("clamp_max", 0.0)))
		ok = _assert(clamp_max_matches, "Canonical channel %s should keep default clamp_max" % channel_id) and ok
		var metadata_expected_variant: Variant = expected_channel.get("metadata")
		ok = _assert(metadata_expected_variant is Dictionary, "Canonical channel %s should define metadata expectations" % channel_id) and ok
		if metadata_expected_variant is Dictionary:
			ok = _assert(_metadata_matches_expectations(channel.get("metadata"), metadata_expected_variant as Dictionary), "Canonical channel %s metadata should match expected contract" % channel_id) and ok

	var serialized: Dictionary = registry.to_dict()
	ok = _assert(serialized.get("schema_version") == 1, "Registry to_dict should include schema_version") and ok
	ok = _assert(String(serialized.get("registry_id")) == "default_registry", "Registry to_dict should include registry_id") and ok
	var serialized_channels: Variant = serialized.get("channels")
	if serialized_channels == null:
		serialized_channels = []
	ok = _assert(serialized_channels is Array, "Registry to_dict should include channels") and ok
	ok = _assert((serialized_channels as Array).size() == registry.channels.size(), "Registry to_dict should serialize all channels") and ok

	var rebuilt := _new_registry()
	if rebuilt == null:
		return false
	rebuilt.from_dict({
		"registry_id": "   ",
		"map_width": 0,
		"map_height": 0,
		"voxel_world_height": 0,
		"channels": serialized_channels,
	})
	ok = _assert(rebuilt.registry_id == "default_registry", "Registry from_dict should normalize blank registry_id") and ok
	ok = _assert(rebuilt.map_width == 1, "Registry from_dict should clamp map_width to at least 1") and ok
	ok = _assert(rebuilt.map_height == 1, "Registry from_dict should clamp map_height to at least 1") and ok
	ok = _assert(rebuilt.voxel_world_height == 1, "Registry from_dict should clamp voxel_world_height to at least 1") and ok
	ok = _assert(_has_default_channels_in_any_order(rebuilt.channels, canonical_ids), "Rebuilt registry should keep canonical channel IDs") and ok
	return ok

func _test_validate_canonical_channel_contracts() -> bool:
	var registry := _new_registry()
	if registry == null:
		return false
	registry.ensure_defaults()

	var baseline_validation: Dictionary = registry.validate_canonical_channel_contracts(false)
	var baseline_errors_variant = baseline_validation.get("errors", [])
	var baseline_errors: Array = baseline_errors_variant if baseline_errors_variant is Array else []
	var ok := _assert(bool(baseline_validation.get("ok", false)), "Baseline validation should pass for canonical defaults")
	ok = _assert(baseline_errors.is_empty(), "Baseline validation should return zero canonical metadata errors") and ok

	var mass_density_channel: Resource = _find_channel_by_id(registry.channels, "mass_density")
	ok = _assert(mass_density_channel != null, "mass_density canonical channel should be available for validation mutation") and ok
	if mass_density_channel == null:
		return false

	var corrupted_metadata := _expected_metadata_for_canonical_channel("mass_density")
	corrupted_metadata["unit"] = "kg"
	corrupted_metadata["strict"] = false
	corrupted_metadata["canonical"] = false
	var corrupted_range := corrupted_metadata.get("range", {})
	if corrupted_range is Dictionary:
		corrupted_range = (corrupted_range as Dictionary).duplicate(true)
		corrupted_range["min"] = 1000.0
		corrupted_range["max"] = 10.0
		corrupted_metadata["range"] = corrupted_range
	mass_density_channel.set("metadata", corrupted_metadata)

	var report_without_fix: Dictionary = registry.validate_canonical_channel_contracts(false)
	ok = _assert(not bool(report_without_fix.get("ok", true)), "Invalid canonical metadata should fail validation in non-enforcing mode") and ok
	var non_enforcing_errors_variant = report_without_fix.get("errors", [])
	var non_enforcing_errors: Array = non_enforcing_errors_variant if non_enforcing_errors_variant is Array else []
	ok = _assert(non_enforcing_errors.size() > 0, "Invalid canonical metadata should emit at least one validation error") and ok
	var metadata_after_non_enforcing := mass_density_channel.get("metadata")
	ok = _assert(metadata_after_non_enforcing is Dictionary and String((metadata_after_non_enforcing as Dictionary).get("unit", "")) == "kg", "Non-enforcing validation should not mutate invalid canonical metadata") and ok

	var report_with_fix: Dictionary = registry.validate_canonical_channel_contracts(true)
	ok = _assert(not bool(report_with_fix.get("ok", true)), "Invalid canonical metadata should still report errors when repaired") and ok
	var restored_metadata_variant := mass_density_channel.get("metadata")
	ok = _assert(_metadata_matches_expectations(
		restored_metadata_variant,
		_expected_metadata_for_canonical_channel("mass_density")
	), "Enforced validation should restore canonical mass_density metadata contract") and ok

	var sparse := _new_registry()
	if sparse == null:
		return false
	sparse.channels.clear()
	var custom := _new_channel()
	if custom == null:
		return false
	custom.channel_id = "custom_density_override"
	sparse.channels.append(custom)
	var missing_report: Dictionary = sparse.validate_canonical_channel_contracts(true)
	ok = _assert(len(sparse.channels) > 1, "Validation should inject canonical channels when absent") and ok
	ok = _assert(not bool(missing_report.get("ok", true)), "Missing canonical channels should produce a validation report with errors") and ok
	ok = _assert(_has_default_channels_in_any_order(_canonical_channels_only(sparse.channels), _canonical_field_ids()), "Validation should restore canonical channel IDs for sparse registry") and ok
	return ok

func _test_channel_resource_save_load_serialization() -> bool:
	var channel = _new_channel()
	if channel == null:
		return false
	channel.channel_id = "temperature"
	channel.default_value = 12.5
	channel.metadata = {"units": "celsius"}

	var temp_dir := ProjectSettings.globalize_path(TEMP_RESOURCE_PATH).get_base_dir()
	DirAccess.make_dir_recursive_absolute(temp_dir)

	var err := ResourceSaver.save(channel, TEMP_RESOURCE_PATH)
	var ok := _assert(err == OK, "ResourceSaver.save should persist FieldChannelConfig resource")
	if not ok:
		return false

	var loaded := ResourceLoader.load(TEMP_RESOURCE_PATH)
	ok = _assert(loaded != null, "ResourceLoader.load should load saved FieldChannelConfig resource") and ok
	if loaded != null:
		ok = _assert(String(loaded.get("channel_id")) == "temperature", "Loaded channel should keep channel_id") and ok
		ok = _assert(is_equal_approx(float(loaded.get("default_value")), 12.5), "Loaded channel should keep default_value") and ok
		var metadata_variant = loaded.get("metadata")
		var metadata: Dictionary = metadata_variant if metadata_variant is Dictionary else {}
		ok = _assert(String(metadata.get("units", "")) == "celsius", "Loaded channel should keep metadata") and ok

	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP_RESOURCE_PATH))
	return ok

func _test_bounded_runtime_timeout_defaults() -> bool:
	var file := FileAccess.open(BOUNDED_RUNTIME_SCRIPT_PATH, FileAccess.READ)
	if file == null:
		return _assert(false, "Failed to open bounded runtime test harness script")
	var source := file.get_as_text()
	var ok := true
	ok = _assert(source.contains("const DEFAULT_TIMEOUT_SECONDS := 120"), "Expected DEFAULT_TIMEOUT_SECONDS = 120 in bounded runtime harness") and ok
	ok = _assert(source.contains("const GPU_MOBILE_TIMEOUT_SECONDS := 180"), "Expected GPU_MOBILE_TIMEOUT_SECONDS = 180 in bounded runtime harness") and ok
	return ok

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition

func _metadata_matches_expectations(actual_metadata_variant: Variant, expected_metadata: Dictionary) -> bool:
	if not (actual_metadata_variant is Dictionary):
		return false
	var actual_metadata := actual_metadata_variant as Dictionary
	var actual_keys: Array = actual_metadata.keys()
	var expected_keys: Array = expected_metadata.keys()
	actual_keys.sort()
	expected_keys.sort()
	if actual_keys != expected_keys:
		return false
	for key in expected_keys:
		if key == "range":
			var expected_range_variant: Variant = expected_metadata.get(key)
			if not (expected_range_variant is Dictionary):
				return false
			var expected_range := expected_range_variant as Dictionary
			var actual_range_variant: Variant = actual_metadata.get(key, {})
			if not (actual_range_variant is Dictionary):
				return false
			var actual_range := actual_range_variant as Dictionary
			for bound in ["min", "max"]:
				if not expected_range.has(bound):
					return false
				if not is_equal_approx(float(actual_range.get(bound)), float(expected_range.get(bound))):
					return false
			continue
		var expected_value := expected_metadata.get(key)
		var actual_value := actual_metadata.get(key)
		if expected_value is float or expected_value is int:
			if not is_equal_approx(float(actual_value), float(expected_value)):
				return false
		elif actual_value != expected_value:
			return false
	return true

func _find_channel_by_id(channels: Array, target_channel_id: String) -> Resource:
	for channel_variant in channels:
		if not (channel_variant is Resource):
			continue
		var channel_id := String((channel_variant as Resource).get("channel_id"))
		if channel_id == target_channel_id:
			return channel_variant
	return null

func _expected_metadata_for_canonical_channel(channel_id: String) -> Dictionary:
	var expected_channel_variant: Variant = CANONICAL_FIELD_DEFAULTS_BY_ID.get(channel_id, {})
	if not (expected_channel_variant is Dictionary):
		return {}
	var expected_metadata_variant: Variant = (expected_channel_variant as Dictionary).get("metadata", {})
	if expected_metadata_variant is Dictionary:
		return (expected_metadata_variant as Dictionary).duplicate(true)
	return {}

func _canonical_field_ids() -> Array[String]:
	var ids: Array[String] = []
	for key in CANONICAL_FIELD_DEFAULTS_BY_ID.keys():
		ids.append(String(key))
	ids.sort()
	return ids

func _has_default_channels_in_any_order(channels: Array, expected_channel_ids: Array[String]) -> bool:
	var actual := []
	for channel in channels:
		if channel is Resource:
			actual.append(String((channel as Resource).get("channel_id")))
	var expected = expected_channel_ids.duplicate()
	actual.sort()
	expected.sort()
	return actual == expected

func _canonical_channels_only(channels: Array) -> Array:
	var filtered := []
	for channel in channels:
		if not (channel is Resource):
			continue
		var channel_id := String((channel as Resource).get("channel_id"))
		if CANONICAL_FIELD_DEFAULTS_BY_ID.has(channel_id):
			filtered.append(channel)
	return filtered

func _new_registry() -> Resource:
	var script = load(FIELD_REGISTRY_SCRIPT_PATH)
	if script == null or not script.has_method("new"):
		_assert(false, "Failed to load FieldRegistryConfig resource script")
		return null
	return script.new()

func _new_channel() -> Resource:
	var script = load(FIELD_CHANNEL_SCRIPT_PATH)
	if script == null or not script.has_method("new"):
		_assert(false, "Failed to load FieldChannelConfig resource script")
		return null
	return script.new()
