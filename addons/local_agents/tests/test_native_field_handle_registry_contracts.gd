@tool
extends RefCounted

const INTERFACES_HPP_PATH := "res://addons/local_agents/gdextensions/localagents/include/LocalAgentsSimulationInterfaces.hpp"
const REGISTRY_HPP_PATH := "res://addons/local_agents/gdextensions/localagents/include/LocalAgentsFieldRegistry.hpp"
const REGISTRY_CPP_PATH := "res://addons/local_agents/gdextensions/localagents/src/LocalAgentsFieldRegistry.cpp"
const ExtensionLoader := preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const CORE_SINGLETON_NAME := "LocalAgentsSimulationCore"

func run_test(_tree: SceneTree) -> bool:
	var ok := true
	ok = _test_configure_validation_reason_contracts() and ok
	ok = _test_interfaces_declare_field_handle_contract() and ok
	ok = _test_registry_header_declares_field_handle_overrides() and ok
	ok = _test_registry_cpp_defines_deterministic_handle_contracts() and ok
	ok = _test_registry_cpp_defines_resolve_and_snapshot_contracts() and ok
	ok = _test_registry_refresh_and_clear_handle_state_contracts() and ok
	if ok:
		print("Native field-handle registry source contracts passed (Wave A handles + invariants).")
	return ok

func _test_configure_validation_reason_contracts() -> bool:
	if not ExtensionLoader.ensure_initialized():
		return _assert(false, "LocalAgentsExtensionLoader should be initialized for native runtime registry validation test.")
	if not Engine.has_singleton(CORE_SINGLETON_NAME):
		return _assert(false, "Native simulation core singleton should be available for runtime registry validation test.")
	var core = Engine.get_singleton(CORE_SINGLETON_NAME)
	if core == null:
		return _assert(false, "LocalAgentsSimulationCore singleton should be non-null for runtime registry validation test.")
	var ok := true

	var valid_payload := {
		"fields": [
			{"field_name": "mass_density", "metadata": {"unit": "kg/m^3", "range": {"min": 0.0, "max": 1000000.0}}
			}
		]
	}
	ok = _assert(bool(core.call("configure_field_registry", valid_payload)), "configure_field_registry should accept valid strict metadata.")
	if not ok:
		return false
	var valid_status := _extract_configure_status(core)
	ok = _assert(valid_status.get("ok", false) == true, "Successful configuration should report ok=true.")
	ok = _assert(valid_status.get("operation", "") == "configure", "configure_field_registry status should expose operation=configure on success.")
	ok = _assert(int(valid_status.get("failures", []).size()) == 0, "Successful configure should expose no validation failures.")
	if not ok:
		return false

	var invalid_unit_payload := {
		"fields": [
			{"field_name": "mass_density", "metadata": {"range": {"min": 0.0, "max": 1.0}}
			}
		]
	}
	ok = _assert(not bool(core.call("configure_field_registry", invalid_unit_payload)), "configure_field_registry should reject missing metadata.unit.")
	var missing_unit_status := _extract_configure_status(core)
	var missing_unit_reasons = missing_unit_status.get("failures", [])
	ok = _assert(missing_unit_reasons is Array and missing_unit_reasons.size() > 0, "Missing unit rejection should emit at least one structured failure reason.")
	if missing_unit_reasons is Array and missing_unit_reasons.size() > 0:
		var reason_variant = missing_unit_reasons[0]
		ok = _assert(reason_variant is Dictionary and String(reason_variant.get("reason", "")) == "metadata_unit_missing", "Missing unit rejection should report metadata_unit_missing.")

	var non_numeric_range_payload := {
		"fields": [
			{"field_name": "mass_density", "metadata": {"unit": "kg/m^3", "range": {"min": "low", "max": 1.0}}
			}
		]
	}
	ok = _assert(not bool(core.call("configure_field_registry", non_numeric_range_payload)), "configure_field_registry should reject non-numeric metadata.range min.")
	var non_numeric_status := _extract_configure_status(core)
	var non_numeric_reasons = non_numeric_status.get("failures", [])
	ok = _assert(non_numeric_reasons is Array and non_numeric_reasons.size() > 0, "Non-numeric range rejection should emit at least one structured failure reason.")
	if non_numeric_reasons is Array and non_numeric_reasons.size() > 0:
		var reason_variant = non_numeric_reasons[0]
		ok = _assert(reason_variant is Dictionary and String(reason_variant.get("reason", "")) == "metadata_range_min_invalid", "Non-numeric range rejection should report metadata_range_min_invalid.")

	var inverted_range_payload := {
		"fields": [
			{"field_name": "mass_density", "metadata": {"unit": "kg/m^3", "range": {"min": 100.0, "max": 1.0}}
			}
		]
	}
	ok = _assert(not bool(core.call("configure_field_registry", inverted_range_payload)), "configure_field_registry should reject inverted metadata.range values.")
	var inverted_range_status := _extract_configure_status(core)
	var inverted_range_reasons = inverted_range_status.get("failures", [])
	ok = _assert(inverted_range_reasons is Array and inverted_range_reasons.size() > 0, "Inverted range rejection should emit at least one structured failure reason.")
	if inverted_range_reasons is Array and inverted_range_reasons.size() > 0:
		var reason_variant = inverted_range_reasons[0]
		ok = _assert(reason_variant is Dictionary and String(reason_variant.get("reason", "")) == "metadata_range_inverted", "Inverted range rejection should report metadata_range_inverted.")
	return ok

func _extract_configure_status(core) -> Dictionary:
	var snapshot := core.call("get_debug_snapshot")
	if not (snapshot is Dictionary):
		return {}
	var field_registry := snapshot.get("field_registry", {})
	if not (field_registry is Dictionary):
		return {}
	return field_registry.get("configure_status", {})

func _test_interfaces_declare_field_handle_contract() -> bool:
	var source := _read_source(INTERFACES_HPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("virtual godot::Dictionary create_field_handle(const godot::StringName &field_name) = 0;"), "IFieldRegistry must declare create_field_handle contract") and ok
	ok = _assert(source.contains("virtual godot::Dictionary resolve_field_handle(const godot::StringName &handle_id) const = 0;"), "IFieldRegistry must declare resolve_field_handle contract") and ok
	ok = _assert(source.contains("virtual godot::Dictionary list_field_handles_snapshot() const = 0;"), "IFieldRegistry must declare list_field_handles_snapshot contract") and ok
	return ok

func _test_registry_header_declares_field_handle_overrides() -> bool:
	var source := _read_source(REGISTRY_HPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("godot::Dictionary create_field_handle(const godot::StringName &field_name) override;"), "Registry header must override create_field_handle") and ok
	ok = _assert(source.contains("godot::Dictionary resolve_field_handle(const godot::StringName &handle_id) const override;"), "Registry header must override resolve_field_handle") and ok
	ok = _assert(source.contains("godot::Dictionary list_field_handles_snapshot() const override;"), "Registry header must override list_field_handles_snapshot") and ok
	ok = _assert(source.contains("godot::Dictionary handle_by_field_;"), "Registry header must store handles_by_field map") and ok
	ok = _assert(source.contains("godot::Dictionary field_by_handle_;"), "Registry header must store fields_by_handle map") and ok
	ok = _assert(source.contains("godot::Dictionary normalized_schema_by_handle_;"), "Registry header must store normalized_schema_by_handle map") and ok
	return ok

func _test_registry_cpp_defines_deterministic_handle_contracts() -> bool:
	var source := _read_source(REGISTRY_CPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("String build_deterministic_handle_id(const String &field_name)"), "Registry must define deterministic handle builder") and ok
	ok = _assert(source.contains("return String(\"field::\") + field_name;"), "Registry handle ids must use deterministic field:: prefix") and ok
	ok = _assert(source.contains("Dictionary LocalAgentsFieldRegistry::create_field_handle(const StringName &field_name)"), "Registry must define create_field_handle") and ok
	ok = _assert(source.contains("result[\"error\"] = String(\"invalid_field_name\");"), "create_field_handle must fail fast for invalid_field_name") and ok
	ok = _assert(source.contains("result[\"error\"] = String(\"field_not_registered\");"), "create_field_handle must fail fast when field not registered") and ok
	ok = _assert(source.contains("result[\"field_name\"] = field_key;"), "create_field_handle must include field_name in response") and ok
	ok = _assert(source.contains("result[\"handle_id\"] = handle_id;"), "create_field_handle must include handle_id in response") and ok
	ok = _assert(source.contains("result[\"schema_row\"] = static_cast<Dictionary>(normalized_schema_by_handle_[handle_id]).duplicate(true);"), "create_field_handle must include normalized schema_row contract") and ok
	return ok

func _test_registry_cpp_defines_resolve_and_snapshot_contracts() -> bool:
	var source := _read_source(REGISTRY_CPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("Dictionary LocalAgentsFieldRegistry::resolve_field_handle(const StringName &handle_id) const"), "Registry must define resolve_field_handle") and ok
	ok = _assert(source.contains("result[\"error\"] = String(\"invalid_handle_id\");"), "resolve_field_handle must fail fast for invalid_handle_id") and ok
	ok = _assert(source.contains("result[\"error\"] = String(\"field_handle_not_found\");"), "resolve_field_handle must fail fast for unknown handles") and ok
	ok = _assert(source.contains("result[\"handle_id\"] = handle_key;"), "resolve_field_handle must include resolved handle_id") and ok
	ok = _assert(source.contains("result[\"field_name\"] = field_by_handle_[handle_key];"), "resolve_field_handle must include resolved field_name") and ok
	ok = _assert(source.contains("Dictionary LocalAgentsFieldRegistry::list_field_handles_snapshot() const"), "Registry must define list_field_handles_snapshot") and ok
	ok = _assert(source.contains("snapshot[\"handle_count\"] = field_by_handle_.size();"), "Snapshot must expose handle_count") and ok
	ok = _assert(source.contains("snapshot[\"handles_by_field\"] = handle_by_field_.duplicate(true);"), "Snapshot must expose handles_by_field") and ok
	ok = _assert(source.contains("snapshot[\"fields_by_handle\"] = field_by_handle_.duplicate(true);"), "Snapshot must expose fields_by_handle") and ok
	ok = _assert(source.contains("snapshot[\"normalized_schema_by_handle\"] = normalized_schema_by_handle_.duplicate(true);"), "Snapshot must expose normalized_schema_by_handle") and ok
	return ok

func _test_registry_refresh_and_clear_handle_state_contracts() -> bool:
	var source := _read_source(REGISTRY_CPP_PATH)
	if source == "":
		return false
	var ok := true
	ok = _assert(source.contains("refresh_field_handle_mappings();"), "Registry must refresh handle mappings after registry mutations") and ok
	ok = _assert(source.contains("handle_by_field_.clear();"), "Registry clear() must clear handle_by_field state") and ok
	ok = _assert(source.contains("field_by_handle_.clear();"), "Registry clear() must clear field_by_handle state") and ok
	ok = _assert(source.contains("normalized_schema_by_handle_.clear();"), "Registry clear() must clear normalized_schema_by_handle state") and ok
	ok = _assert(source.contains("schema_with_handle[\"handle_id\"] = handle_id;"), "Refresh mapping must stamp handle_id into schema rows") and ok
	ok = _assert(source.contains("next_handle_by_field[field_name] = handle_id;"), "Refresh mapping must rebuild handle_by_field map deterministically") and ok
	ok = _assert(source.contains("next_field_by_handle[handle_id] = field_name;"), "Refresh mapping must rebuild field_by_handle map deterministically") and ok
	return ok

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition

func _read_source(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_assert(false, "Failed to open source: %s" % path)
		return ""
	return file.get_as_text()
