@tool
extends RefCounted

const FIELD_CHANNEL_SCRIPT_PATH := "res://addons/local_agents/configuration/parameters/simulation/FieldChannelConfigResource.gd"
const FIELD_REGISTRY_SCRIPT_PATH := "res://addons/local_agents/configuration/parameters/simulation/FieldRegistryConfigResource.gd"

const BOUNDED_RUNTIME_SCRIPT_PATH := "res://addons/local_agents/tests/run_runtime_tests_bounded.gd"
const TEMP_RESOURCE_PATH := "user://local_agents/tests/tmp_field_registry_config_resource.tres"

func run_test(_tree: SceneTree) -> bool:
	var ok := true
	ok = _test_channel_round_trip_and_normalization() and ok
	ok = _test_registry_serialization_contract_source() and ok
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

func _test_registry_serialization_contract_source() -> bool:
	var source := _read_script_source(FIELD_REGISTRY_SCRIPT_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("@export var registry_id: String = \"default_registry\""), "Registry should define default registry_id") and ok
	ok = _assert(source.contains("@export var map_width: int = 24"), "Registry should define default map_width") and ok
	ok = _assert(source.contains("@export var map_height: int = 24"), "Registry should define default map_height") and ok
	ok = _assert(source.contains("@export var voxel_world_height: int = 36"), "Registry should define default voxel_world_height") and ok
	ok = _assert(source.contains("\"schema_version\": schema_version"), "Registry to_dict should include schema_version") and ok
	ok = _assert(source.contains("\"registry_id\": registry_id"), "Registry to_dict should include registry_id") and ok
	ok = _assert(source.contains("\"channels\": channel_rows"), "Registry to_dict should include channels") and ok
	ok = _assert(source.contains("channel_rows.append(channel.to_dict())"), "Registry serialization should delegate channel to_dict") and ok
	ok = _assert(source.contains("row.from_dict(row_variant as Dictionary)"), "Registry deserialization should delegate channel from_dict") and ok
	ok = _assert(source.contains("if registry_id == \"\":\n\t\tregistry_id = \"default_registry\""), "Registry from_dict should normalize blank registry_id") and ok
	ok = _assert(source.contains("map_width = maxi(1, int(values.get(\"map_width\", map_width)))"), "Registry from_dict should bound map_width") and ok
	ok = _assert(source.contains("map_height = maxi(1, int(values.get(\"map_height\", map_height)))"), "Registry from_dict should bound map_height") and ok
	ok = _assert(source.contains("voxel_world_height = maxi(1, int(values.get(\"voxel_world_height\", voxel_world_height)))"), "Registry from_dict should bound voxel_world_height") and ok
	for channel_id in ["temperature", "humidity", "surface_water", "flow_strength", "erosion_potential", "solar_exposure"]:
		ok = _assert(source.contains("_make_channel(\"%s\")" % channel_id), "Registry ensure_defaults missing channel %s" % channel_id) and ok
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

func _read_script_source(script_path: String) -> String:
	var file := FileAccess.open(script_path, FileAccess.READ)
	if file == null:
		_assert(false, "Failed to open script source: %s" % script_path)
		return ""
	return file.get_as_text()

func _new_channel() -> Resource:
	var script = load(FIELD_CHANNEL_SCRIPT_PATH)
	if script == null or not script.has_method("new"):
		_assert(false, "Failed to load FieldChannelConfig resource script")
		return null
	return script.new()
