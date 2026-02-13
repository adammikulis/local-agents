extends RefCounted

const NATIVE_SIM_CORE_SINGLETON_NAME := "LocalAgentsSimulationCore"
const NATIVE_SIM_CORE_ENV_KEY := "LOCAL_AGENTS_ENABLE_NATIVE_SIM_CORE"
const _CANONICAL_INPUT_KEYS := [
	"pressure",
	"temperature",
	"density",
	"velocity",
	"moisture",
	"porosity",
	"cohesion",
	"hardness",
	"phase",
	"stress",
	"strain",
	"fuel",
	"oxygen",
	"material_flammability",
	"activity",
]

static func is_native_sim_core_enabled() -> bool:
	return OS.get_environment(NATIVE_SIM_CORE_ENV_KEY).strip_edges() == "1"

static func dispatch_stage_call(controller, tick: int, phase: String, method_name: String, args: Array = [], strict: bool = false) -> Dictionary:
	if not is_native_sim_core_enabled():
		var disabled_error = "native_sim_core_disabled"
		if strict:
			controller._emit_dependency_error(tick, phase, disabled_error)
		return {
			"ok": false,
			"executed": false,
			"error": disabled_error,
		}

	if not Engine.has_singleton(NATIVE_SIM_CORE_SINGLETON_NAME):
		var unavailable_error = "native_sim_core_unavailable"
		if strict:
			controller._emit_dependency_error(tick, phase, unavailable_error)
		return {
			"ok": false,
			"executed": false,
			"error": unavailable_error,
		}

	var core = Engine.get_singleton(NATIVE_SIM_CORE_SINGLETON_NAME)
	if core == null:
		var core_missing_error = "native_sim_core_unavailable"
		if strict:
			controller._emit_dependency_error(tick, phase, core_missing_error)
		return {
			"ok": false,
			"executed": false,
			"error": core_missing_error,
		}

	if not core.has_method(method_name):
		var missing_method_error = "core_missing_method_%s" % method_name
		if strict:
			controller._emit_dependency_error(tick, phase, missing_method_error)
		return {
			"ok": false,
			"executed": false,
			"error": missing_method_error,
		}

	var result = core.callv(method_name, args)
	return _normalize_dispatch_result(controller, tick, phase, method_name, result, strict)

static func dispatch_voxel_stage(stage_name: StringName, payload: Dictionary = {}) -> Dictionary:
	if not is_native_sim_core_enabled():
		return {"ok": false, "executed": false, "dispatched": false, "error": "native_sim_core_disabled"}
	if not Engine.has_singleton(NATIVE_SIM_CORE_SINGLETON_NAME):
		return {"ok": false, "executed": false, "dispatched": false, "error": "native_sim_core_unavailable"}
	var core = Engine.get_singleton(NATIVE_SIM_CORE_SINGLETON_NAME)
	if core == null or not core.has_method("execute_voxel_stage"):
		return {"ok": false, "executed": false, "dispatched": false, "error": "core_missing_method_execute_voxel_stage"}
	var result = core.call("execute_voxel_stage", stage_name, payload)
	return _normalize_voxel_stage_result(result)

static func dispatch_voxel_stage_call(controller, tick: int, phase: String, stage_name: StringName, payload: Dictionary = {}, strict: bool = false) -> Dictionary:
	return dispatch_stage_call(controller, tick, phase, "execute_voxel_stage", [stage_name, payload], strict)

static func dispatch_voxel_edit_enqueue_call(controller, tick: int, phase: String, voxel_ops: Array, strict: bool = false) -> Dictionary:
	return dispatch_stage_call(controller, tick, phase, "enqueue_voxel_edit_ops", [voxel_ops], strict)

static func is_voxel_stage_dispatched(dispatch: Dictionary) -> bool:
	if not bool(dispatch.get("ok", false)):
		return false
	var result = dispatch.get("result", {})
	if not (result is Dictionary):
		return false
	if bool((result as Dictionary).get("dispatched", false)):
		return true
	var execution = (result as Dictionary).get("execution", {})
	if not (execution is Dictionary):
		return false
	return bool((execution as Dictionary).get("dispatched", false))

static func voxel_stage_result(dispatch: Dictionary) -> Dictionary:
	if not bool(dispatch.get("ok", false)):
		return {}
	var native_result = dispatch.get("result", {})
	if not (native_result is Dictionary):
		return {}
	var payload = native_result.get("result", {})
	if payload is Dictionary:
		return payload as Dictionary
	payload = native_result.get("step_result", {})
	if payload is Dictionary:
		return payload as Dictionary
	payload = native_result.get("payload", {})
	if payload is Dictionary:
		return payload as Dictionary
	return native_result as Dictionary

static func dispatch_environment_stage_call(controller, tick: int, phase: String, stage_name: String, payload: Dictionary = {}, strict: bool = false) -> Dictionary:
	var normalized_payload = _normalize_environment_payload(payload)
	return dispatch_stage_call(controller, tick, phase, "execute_environment_stage", [stage_name, normalized_payload], strict)

static func is_environment_stage_dispatched(dispatch: Dictionary) -> bool:
	if not bool(dispatch.get("ok", false)):
		return false
	var result = dispatch.get("result", {})
	if not (result is Dictionary):
		return false
	var execution = (result as Dictionary).get("execution", {})
	if not (execution is Dictionary):
		return false
	return bool((execution as Dictionary).get("dispatched", false))

static func environment_stage_result(dispatch: Dictionary) -> Dictionary:
	if not bool(dispatch.get("ok", false)):
		return {}
	var native_result = dispatch.get("result", {})
	if not (native_result is Dictionary):
		return {}
	var payload = native_result.get("result", {})
	if payload is Dictionary:
		return payload as Dictionary
	payload = native_result.get("step_result", {})
	if payload is Dictionary:
		return payload as Dictionary
	payload = native_result.get("payload", {})
	if payload is Dictionary:
		return payload as Dictionary
	return {}

static func dispatch_environment_stage(stage_name: String, payload: Dictionary) -> Dictionary:
	if not is_native_sim_core_enabled():
		return {
			"ok": false,
			"executed": false,
			"dispatched": false,
			"error": "native_sim_core_disabled",
		}
	if not Engine.has_singleton(NATIVE_SIM_CORE_SINGLETON_NAME):
		return {
			"ok": false,
			"executed": false,
			"dispatched": false,
			"error": "native_sim_core_unavailable",
		}
	var core = Engine.get_singleton(NATIVE_SIM_CORE_SINGLETON_NAME)
	if core == null:
		return {
			"ok": false,
			"executed": false,
			"dispatched": false,
			"error": "native_sim_core_unavailable",
		}
	if not core.has_method("execute_environment_stage"):
		return {
			"ok": false,
			"executed": false,
			"dispatched": false,
			"error": "core_missing_method_execute_environment_stage",
		}
	var normalized_payload = _normalize_environment_payload(payload)
	var result = core.callv("execute_environment_stage", [stage_name, normalized_payload])
	return _normalize_environment_stage_result(result)

static func _normalize_environment_payload(payload: Dictionary) -> Dictionary:
	var normalized: Dictionary = payload.duplicate(true)
	var inputs := _material_inputs_from_payload(normalized)
	normalized["inputs"] = inputs
	return normalized

static func _material_inputs_from_payload(payload: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var explicit_inputs = payload.get("inputs", {})
	if explicit_inputs is Dictionary:
		out = (explicit_inputs as Dictionary).duplicate(true)

	for key_variant in _CANONICAL_INPUT_KEYS:
		var key = String(key_variant)
		if out.has(key):
			continue
		if payload.has(key):
			out[key] = payload.get(key)

	# Pull common channels from snapshots when available so weather/hydrology/erosion/solar
	# adapters can share one native material-state input contract.
	var environment = payload.get("environment", {})
	if environment is Dictionary:
		var env = environment as Dictionary
		var view_metrics = env.get("_native_view_metrics", {})
		if view_metrics is Dictionary:
			var vm = view_metrics as Dictionary
			if not out.has("activity") and vm.has("compute_budget_scale"):
				out["activity"] = clampf(float(vm.get("compute_budget_scale", 1.0)), 0.0, 1.0)

	var hydrology = payload.get("hydrology", {})
	if hydrology is Dictionary:
		var water_tiles = (hydrology as Dictionary).get("water_tiles", {})
		if water_tiles is Dictionary and not (water_tiles as Dictionary).is_empty():
			if not out.has("pressure"):
				out["pressure"] = _average_tile_metric(water_tiles as Dictionary, "hydraulic_pressure", 1.0)
			if not out.has("moisture"):
				out["moisture"] = _average_tile_metric(water_tiles as Dictionary, "water_reliability", 0.0)

	var weather = payload.get("weather", {})
	if weather is Dictionary:
		var weather_dict = weather as Dictionary
		if not out.has("temperature"):
			out["temperature"] = 273.15 + clampf(float(weather_dict.get("avg_temperature", 0.5)), 0.0, 1.0) * 70.0
		if not out.has("oxygen"):
			out["oxygen"] = clampf(float(weather_dict.get("avg_humidity", 0.35)) * 0.0 + 0.21, 0.0, 1.0)
		if not out.has("density"):
			out["density"] = 1.0
		if not out.has("velocity"):
			out["velocity"] = clampf(float(weather_dict.get("avg_wind_speed", 0.0)), 0.0, 1000.0)

	if not out.has("temperature"):
		out["temperature"] = 293.0
	if not out.has("pressure"):
		out["pressure"] = 1.0
	if not out.has("density"):
		out["density"] = 1.0
	if not out.has("velocity"):
		out["velocity"] = 0.0
	if not out.has("moisture"):
		out["moisture"] = 0.0
	if not out.has("porosity"):
		out["porosity"] = 0.25
	if not out.has("cohesion"):
		out["cohesion"] = 0.5
	if not out.has("hardness"):
		out["hardness"] = 0.5
	if not out.has("phase"):
		out["phase"] = 0
	if not out.has("stress"):
		out["stress"] = 0.0
	if not out.has("strain"):
		out["strain"] = 0.0
	if not out.has("fuel"):
		out["fuel"] = 0.0
	if not out.has("oxygen"):
		out["oxygen"] = 0.21
	if not out.has("material_flammability"):
		out["material_flammability"] = 0.5
	if not out.has("activity"):
		out["activity"] = 0.0
	return out

static func _average_tile_metric(rows: Dictionary, key: String, fallback: float) -> float:
	var total := 0.0
	var count := 0
	for row_variant in rows.values():
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		if not row.has(key):
			continue
		total += float(row.get(key, fallback))
		count += 1
	if count <= 0:
		return fallback
	return total / float(count)

static func _normalize_environment_stage_result(result) -> Dictionary:
	if result is Dictionary:
		var payload = result as Dictionary
		var dispatched = bool(payload.get("dispatched", false))
		if not dispatched and payload.get("execution", {}) is Dictionary:
			dispatched = bool((payload.get("execution", {}) as Dictionary).get("dispatched", false))
		var result_fields: Dictionary = {}
		if payload.get("result_fields", {}) is Dictionary:
			result_fields = (payload.get("result_fields", {}) as Dictionary)
		elif payload.get("result", {}) is Dictionary:
			result_fields = (payload.get("result", {}) as Dictionary)
			if result_fields.get("result_fields", {}) is Dictionary:
				result_fields = (result_fields.get("result_fields", {}) as Dictionary)
		elif payload.get("step_result", {}) is Dictionary:
			result_fields = (payload.get("step_result", {}) as Dictionary)
		elif payload.get("payload", {}) is Dictionary:
			result_fields = (payload.get("payload", {}) as Dictionary)
		return {
			"ok": bool(payload.get("ok", true)),
			"executed": true,
			"dispatched": dispatched,
			"result": payload,
			"result_fields": result_fields,
			"error": String(payload.get("error", "")),
		}
	if result is bool:
		return {
			"ok": bool(result),
			"executed": true,
			"dispatched": bool(result),
			"result": result,
			"result_fields": {},
			"error": "",
		}
	return {
		"ok": false,
		"executed": true,
		"dispatched": false,
		"result": result,
		"result_fields": {},
		"error": "core_call_invalid_response_execute_environment_stage",
	}

static func _normalize_voxel_stage_result(result) -> Dictionary:
	if not (result is Dictionary):
		return {"ok": false, "executed": true, "dispatched": false, "error": "core_call_invalid_response_execute_voxel_stage"}
	var payload_result = result as Dictionary
	var dispatched = bool(payload_result.get("dispatched", false))
	if not dispatched:
		var execution_variant = payload_result.get("execution", {})
		if execution_variant is Dictionary:
			dispatched = bool((execution_variant as Dictionary).get("dispatched", false))
	return {
		"ok": bool(payload_result.get("ok", false)),
		"executed": true,
		"dispatched": dispatched,
		"result": payload_result,
		"error": String(payload_result.get("error", "")),
	}

static func _normalize_dispatch_result(controller, tick: int, phase: String, method_name: String, result, strict: bool) -> Dictionary:
	if result is bool:
		if bool(result):
			return {
				"ok": true,
				"executed": true,
				"result": result,
			}
		return _dispatch_error(controller, tick, phase, "core_call_failed_%s" % method_name, strict)

	if result is Dictionary:
		var payload = result as Dictionary
		if bool(payload.get("ok", false)):
			return {
				"ok": true,
				"executed": true,
				"result": payload,
			}
		return _dispatch_error(
			controller,
			tick,
			phase,
			String(payload.get("error", "core_call_failed_%s" % method_name)),
			strict
		)

	if result == null:
		return _dispatch_error(controller, tick, phase, "core_call_null_%s" % method_name, strict)

	return _dispatch_error(controller, tick, phase, "core_call_invalid_response_%s" % method_name, strict)

static func _dispatch_error(controller, tick: int, phase: String, error_code: String, strict: bool) -> Dictionary:
	if strict:
		controller._emit_dependency_error(tick, phase, error_code)
	return {
		"ok": false,
		"executed": true,
		"error": error_code,
	}
