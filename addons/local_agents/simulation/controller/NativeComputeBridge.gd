extends RefCounted

const NATIVE_SIM_CORE_SINGLETON_NAME := "LocalAgentsSimulationCore"
const NATIVE_SIM_CORE_ENV_KEY := "LOCAL_AGENTS_ENABLE_NATIVE_SIM_CORE"
const _CANONICAL_INPUT_KEYS := [
	"pressure",
	"pressure_gradient",
	"temperature",
	"density",
	"velocity",
	"force_proxy",
	"acceleration_proxy",
	"mass_proxy",
	"moisture",
	"porosity",
	"cohesion",
	"hardness",
	"phase",
	"stress",
	"strain",
	"thermal_conductivity",
	"thermal_capacity",
	"thermal_diffusivity",
	"reaction_rate",
	"reaction_channels",
	"phase_change_channels",
	"porous_flow_channels",
	"shock_impulse_channels",
	"friction_contact_channels",
	"boundary_condition_channels",
	"fuel",
	"oxygen",
	"material_flammability",
	"activity",
]
const _DEFAULT_REACTION_CHANNELS := {
	"combustion": 0.0,
	"oxidation": 0.0,
	"hydration": 0.0,
	"decomposition": 0.0,
	"corrosion": 0.0,
}
const _DEFAULT_GENERALIZED_CHANNELS := {"phase_change_channels": {"melting": 0.0, "freezing": 0.0, "evaporation": 0.0, "condensation": 0.0}, "porous_flow_channels": {"seepage": 0.0, "capillary": 0.0, "drainage": 0.0, "retention": 0.0}, "shock_impulse_channels": {"impact": 0.0, "blast": 0.0, "shear_wave": 0.0, "vibration": 0.0}, "friction_contact_channels": {"static": 0.0, "kinetic": 0.0, "rolling": 0.0, "adhesion": 0.0}, "boundary_condition_channels": {"dirichlet": 0.0, "neumann": 0.0, "robin": 0.0, "reflective": 0.0, "periodic": 0.0}}
const _MATERIAL_INPUT_DEFAULTS := {
	"temperature": 293.0, "pressure": 1.0, "pressure_gradient": 0.0, "density": 1.0, "velocity": 0.0, "moisture": 0.0, "porosity": 0.25, "cohesion": 0.5, "hardness": 0.5, "phase": 0, "stress": 0.0, "strain": 0.0, "fuel": 0.0, "oxygen": 0.21, "material_flammability": 0.5, "activity": 0.0,
	"thermal_conductivity": -1.0, "thermal_capacity": -1.0, "thermal_diffusivity": -1.0, "reaction_rate": -1.0, "reaction_channels": {}, "phase_change_channels": {}, "porous_flow_channels": {}, "shock_impulse_channels": {}, "friction_contact_channels": {}, "boundary_condition_channels": {},
	"mass_proxy": -1.0, "acceleration_proxy": -1.0, "force_proxy": -1.0,
}
const _LEGACY_INPUT_KEY_ALIASES := {
	"temperature": ["temp", "temp_k", "avg_temperature"],
	"pressure": ["pressure_atm", "atmospheric_pressure", "hydraulic_pressure"],
	"pressure_gradient": ["pressure_delta", "pressure_grad", "hydraulic_gradient"],
	"density": ["air_density", "material_density"],
	"velocity": ["wind_speed", "flow_speed", "speed"],
	"mass_proxy": ["mass", "mass_estimate", "inertial_mass"],
	"acceleration_proxy": ["acceleration", "accel", "accel_proxy"],
	"force_proxy": ["force", "force_estimate", "impulse"],
	"moisture": ["humidity", "water_content"],
	"porosity": ["void_fraction"],
	"cohesion": ["binding_strength"],
	"hardness": ["rigidity", "resistance"],
	"thermal_conductivity": ["conductivity", "thermal_k"],
	"thermal_capacity": ["heat_capacity", "specific_heat"],
	"thermal_diffusivity": ["diffusivity"],
	"reaction_rate": ["reaction_intensity", "chem_reaction_rate"],
	"phase_change_channels": ["phase_transitions", "phase_change", "transition_channels"],
	"porous_flow_channels": ["porous_channels", "flow_channels", "permeability_channels"],
	"shock_impulse_channels": ["shock_channels", "impulse_channels", "impact_channels"],
	"friction_contact_channels": ["friction_channels", "contact_channels", "tribology_channels"],
	"boundary_condition_channels": ["boundary_channels", "boundary_conditions", "bc_channels"],
	"material_flammability": ["flammability"],
	"activity": ["activity_level", "activation"],
}
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
	_merge_payload_material_input_overrides(out, payload)
	_merge_environment_activity(out, payload)
	_merge_hydrology_material_inputs(out, payload)
	_merge_weather_material_inputs(out, payload)
	_apply_material_input_defaults(out)
	return _normalize_canonical_material_inputs(out)

static func _merge_payload_material_input_overrides(out: Dictionary, payload: Dictionary) -> void:
	for key_variant in _CANONICAL_INPUT_KEYS:
		var key = String(key_variant)
		if out.has(key):
			continue
		if payload.has(key):
			out[key] = payload.get(key)

	for canonical_variant in _LEGACY_INPUT_KEY_ALIASES.keys():
		var canonical_key := String(canonical_variant)
		if out.has(canonical_key):
			continue
		var aliases_variant = _LEGACY_INPUT_KEY_ALIASES.get(canonical_key, [])
		if not (aliases_variant is Array):
			continue
		for alias_variant in aliases_variant:
			var alias_key := String(alias_variant)
			if payload.has(alias_key):
				out[canonical_key] = payload.get(alias_key)
				break

static func _merge_environment_activity(out: Dictionary, payload: Dictionary) -> void:
	var environment = payload.get("environment", {})
	if environment is Dictionary:
		var env = environment as Dictionary
		var view_metrics = env.get("_native_view_metrics", {})
		if view_metrics is Dictionary:
			var vm = view_metrics as Dictionary
			if not out.has("activity") and vm.has("compute_budget_scale"):
				out["activity"] = clampf(float(vm.get("compute_budget_scale", 1.0)), 0.0, 1.0)

static func _merge_hydrology_material_inputs(out: Dictionary, payload: Dictionary) -> void:
	var hydrology = payload.get("hydrology", {})
	if not (hydrology is Dictionary):
		return
	var water_tiles = (hydrology as Dictionary).get("water_tiles", {})
	if not (water_tiles is Dictionary):
		return
	if (water_tiles as Dictionary).is_empty():
		return
	if not out.has("pressure"):
		out["pressure"] = _average_tile_metric(water_tiles as Dictionary, "hydraulic_pressure", 1.0)
	if not out.has("moisture"):
		out["moisture"] = _average_tile_metric(water_tiles as Dictionary, "water_reliability", 0.0)
	if not out.has("pressure_gradient"):
		var hydraulic_gradient = _average_tile_metric(water_tiles as Dictionary, "pressure_gradient", -1.0)
		if hydraulic_gradient < 0.0:
			hydraulic_gradient = _average_tile_metric(water_tiles as Dictionary, "hydraulic_gradient", 0.0)
		out["pressure_gradient"] = hydraulic_gradient

static func _merge_weather_material_inputs(out: Dictionary, payload: Dictionary) -> void:
	var weather = payload.get("weather", {})
	if not (weather is Dictionary):
		return
	var weather_dict = weather as Dictionary
	if not out.has("temperature"):
		out["temperature"] = 273.15 + clampf(float(weather_dict.get("avg_temperature", 0.5)), 0.0, 1.0) * 70.0
	if not out.has("oxygen"):
		out["oxygen"] = clampf(float(weather_dict.get("avg_humidity", 0.35)) * 0.0 + 0.21, 0.0, 1.0)
	if not out.has("density"):
		out["density"] = 1.0
	if not out.has("velocity"):
		out["velocity"] = clampf(float(weather_dict.get("avg_wind_speed", 0.0)), 0.0, 200.0)

static func _apply_material_input_defaults(out: Dictionary) -> void:
	for key_variant in _MATERIAL_INPUT_DEFAULTS.keys():
		var key := String(key_variant)
		if out.has(key):
			continue
		var value = _MATERIAL_INPUT_DEFAULTS.get(key)
		if value is Dictionary:
			out[key] = (value as Dictionary).duplicate(true)
		else:
			out[key] = value

static func _normalize_canonical_material_inputs(input_fields: Dictionary) -> Dictionary:
	var out: Dictionary = input_fields.duplicate(true)
	out["temperature"] = _normalize_temperature_input(out.get("temperature", 293.0))
	out["pressure"] = _normalize_pressure_input(out.get("pressure", 1.0))
	out["pressure_gradient"] = _normalize_signed_input(out.get("pressure_gradient", 0.0), 50.0)
	out["density"] = clampf(float(out.get("density", 1.0)), 0.001, 50000.0)
	out["velocity"] = clampf(float(out.get("velocity", 0.0)), 0.0, 200.0)
	out["moisture"] = clampf(float(out.get("moisture", 0.0)), 0.0, 1.0)
	out["porosity"] = clampf(float(out.get("porosity", 0.25)), 0.0, 1.0)
	out["cohesion"] = clampf(float(out.get("cohesion", 0.5)), 0.0, 1.0)
	out["hardness"] = clampf(float(out.get("hardness", 0.5)), 0.0, 1.0)
	out["phase"] = int(out.get("phase", 0))
	out["stress"] = _normalize_signed_input(out.get("stress", 0.0), 5.0e8)
	out["strain"] = clampf(float(out.get("strain", 0.0)), -1.0, 1.0)
	out["fuel"] = clampf(float(out.get("fuel", 0.0)), 0.0, 1.0)
	out["oxygen"] = clampf(float(out.get("oxygen", 0.21)), 0.0, 1.0)
	out["material_flammability"] = clampf(float(out.get("material_flammability", 0.5)), 0.0, 1.0)
	out["activity"] = clampf(float(out.get("activity", 0.0)), 0.0, 1.0)
	out["mass_proxy"] = _normalize_mass_proxy(out)
	out["acceleration_proxy"] = _normalize_acceleration_proxy(out)
	out["force_proxy"] = _normalize_force_proxy(out)
	out["thermal_conductivity"] = _normalize_thermal_conductivity(out)
	out["thermal_capacity"] = _normalize_thermal_capacity(out)
	out["thermal_diffusivity"] = _normalize_thermal_diffusivity(out)
	out["reaction_channels"] = _normalize_reaction_channels(out.get("reaction_channels", {}), out)
	for channel_key_variant in _DEFAULT_GENERALIZED_CHANNELS.keys():
		var channel_key := String(channel_key_variant)
		out[channel_key] = _normalize_contract_channels(out.get(channel_key, {}), _DEFAULT_GENERALIZED_CHANNELS.get(channel_key, {}))
	out["reaction_rate"] = _normalize_reaction_rate(out)
	return out

static func _normalize_temperature_input(raw_value) -> float:
	var value = float(raw_value)
	if value <= 2.0:
		return 173.15 + clampf(value, 0.0, 1.0) * 210.0
	return clampf(value, 120.0, 2200.0)

static func _normalize_pressure_input(raw_value) -> float:
	var value = float(raw_value)
	if value <= 5.0:
		return clampf(value, 0.0, 5.0) * 101325.0
	return clampf(value, 0.0, 5.0e7)

static func _normalize_signed_input(raw_value, max_magnitude: float) -> float:
	return clampf(float(raw_value), -max_magnitude, max_magnitude)

static func _normalize_mass_proxy(inputs: Dictionary) -> float:
	var raw_mass = float(inputs.get("mass_proxy", -1.0))
	if raw_mass >= 0.0:
		if raw_mass > 1.0:
			return clampf(raw_mass / 5000.0, 0.0, 1.0)
		return clampf(raw_mass, 0.0, 1.0)
	var density = float(inputs.get("density", 1.0))
	var porosity = clampf(float(inputs.get("porosity", 0.25)), 0.0, 1.0)
	return clampf((density * (1.0 - porosity)) / 5000.0, 0.0, 1.0)

static func _normalize_acceleration_proxy(inputs: Dictionary) -> float:
	var raw_accel = float(inputs.get("acceleration_proxy", -1.0))
	if raw_accel >= 0.0:
		if raw_accel > 1.0:
			return clampf(raw_accel / 200.0, 0.0, 1.0)
		return clampf(raw_accel, 0.0, 1.0)
	var pressure_grad = absf(float(inputs.get("pressure_gradient", 0.0)))
	var stress_mag = absf(float(inputs.get("stress", 0.0)))
	var strain_mag = absf(float(inputs.get("strain", 0.0)))
	var normalized_grad = clampf(pressure_grad / 50.0, 0.0, 1.0)
	var normalized_stress = clampf(stress_mag / 5.0e8, 0.0, 1.0)
	return clampf(normalized_grad * 0.5 + normalized_stress * 0.35 + strain_mag * 0.15, 0.0, 1.0)

static func _normalize_force_proxy(inputs: Dictionary) -> float:
	var raw_force = float(inputs.get("force_proxy", -1.0))
	if raw_force >= 0.0:
		if raw_force > 1.0:
			return clampf(raw_force / 1.0e6, 0.0, 1.0)
		return clampf(raw_force, 0.0, 1.0)
	var mass_proxy = float(inputs.get("mass_proxy", 0.0))
	var accel_proxy = float(inputs.get("acceleration_proxy", 0.0))
	return clampf(mass_proxy * accel_proxy, 0.0, 1.0)

static func _normalize_thermal_conductivity(inputs: Dictionary) -> float:
	var raw_value = float(inputs.get("thermal_conductivity", -1.0))
	if raw_value >= 0.0:
		if raw_value > 1.0:
			return clampf(raw_value / 400.0, 0.0, 1.0)
		return clampf(raw_value, 0.0, 1.0)
	var hardness = clampf(float(inputs.get("hardness", 0.5)), 0.0, 1.0)
	var moisture = clampf(float(inputs.get("moisture", 0.0)), 0.0, 1.0)
	var porosity = clampf(float(inputs.get("porosity", 0.25)), 0.0, 1.0)
	return clampf(hardness * 0.65 + moisture * 0.25 + (1.0 - porosity) * 0.1, 0.0, 1.0)

static func _normalize_thermal_capacity(inputs: Dictionary) -> float:
	var raw_value = float(inputs.get("thermal_capacity", -1.0))
	if raw_value >= 0.0:
		if raw_value > 1.0:
			return clampf(raw_value / 6000.0, 0.0, 1.0)
		return clampf(raw_value, 0.0, 1.0)
	var moisture = clampf(float(inputs.get("moisture", 0.0)), 0.0, 1.0)
	var density = clampf(float(inputs.get("density", 1.0)) / 5000.0, 0.0, 1.0)
	return clampf(moisture * 0.55 + density * 0.45, 0.0, 1.0)

static func _normalize_thermal_diffusivity(inputs: Dictionary) -> float:
	var raw_value = float(inputs.get("thermal_diffusivity", -1.0))
	if raw_value >= 0.0:
		if raw_value > 1.0:
			return clampf(raw_value / 1.5e-4, 0.0, 1.0)
		return clampf(raw_value, 0.0, 1.0)
	var conductivity = float(inputs.get("thermal_conductivity", 0.5))
	var capacity = maxf(float(inputs.get("thermal_capacity", 0.5)), 0.0001)
	var mass_proxy = maxf(float(inputs.get("mass_proxy", 0.1)), 0.0001)
	return clampf(conductivity / (capacity * (0.3 + mass_proxy)), 0.0, 1.0)

static func _normalize_reaction_channels(channels_variant, inputs: Dictionary) -> Dictionary:
	var channels: Dictionary = _DEFAULT_REACTION_CHANNELS.duplicate(true)
	if channels_variant is Dictionary:
		for key_variant in (channels_variant as Dictionary).keys():
			var key := String(key_variant)
			channels[key] = clampf(float((channels_variant as Dictionary).get(key, 0.0)), 0.0, 1.0)
	var fuel = clampf(float(inputs.get("fuel", 0.0)), 0.0, 1.0)
	var oxygen = clampf(float(inputs.get("oxygen", 0.21)), 0.0, 1.0)
	var flammability = clampf(float(inputs.get("material_flammability", 0.5)), 0.0, 1.0)
	var moisture = clampf(float(inputs.get("moisture", 0.0)), 0.0, 1.0)
	var activity = clampf(float(inputs.get("activity", 0.0)), 0.0, 1.0)
	if not channels.has("combustion") or float(channels.get("combustion", 0.0)) <= 0.0:
		channels["combustion"] = clampf(fuel * oxygen * flammability * (0.35 + activity * 0.65), 0.0, 1.0)
	if not channels.has("oxidation") or float(channels.get("oxidation", 0.0)) <= 0.0:
		channels["oxidation"] = clampf(oxygen * (0.4 + (1.0 - moisture) * 0.6), 0.0, 1.0)
	if not channels.has("hydration") or float(channels.get("hydration", 0.0)) <= 0.0:
		channels["hydration"] = clampf(moisture * (0.55 + activity * 0.45), 0.0, 1.0)
	if not channels.has("decomposition") or float(channels.get("decomposition", 0.0)) <= 0.0:
		var thermal_drive = clampf((float(inputs.get("temperature", 293.0)) - 260.0) / 500.0, 0.0, 1.0)
		channels["decomposition"] = clampf(thermal_drive * (0.45 + activity * 0.55), 0.0, 1.0)
	if not channels.has("corrosion") or float(channels.get("corrosion", 0.0)) <= 0.0:
		channels["corrosion"] = clampf(oxygen * moisture * (0.4 + activity * 0.6), 0.0, 1.0)
	return channels

static func _normalize_contract_channels(channels_variant, defaults_variant) -> Dictionary:
	var defaults: Dictionary = defaults_variant if defaults_variant is Dictionary else {}
	var channels: Dictionary = defaults.duplicate(true)
	if not (channels_variant is Dictionary):
		return channels
	for key_variant in (channels_variant as Dictionary).keys():
		channels[String(key_variant)] = clampf(float((channels_variant as Dictionary).get(key_variant, 0.0)), 0.0, 1.0)
	return channels

static func _normalize_reaction_rate(inputs: Dictionary) -> float:
	var raw_value = float(inputs.get("reaction_rate", -1.0))
	if raw_value >= 0.0:
		if raw_value > 1.0:
			return clampf(raw_value / 100.0, 0.0, 1.0)
		return clampf(raw_value, 0.0, 1.0)
	var channels_variant = inputs.get("reaction_channels", {})
	var channels: Dictionary = channels_variant if channels_variant is Dictionary else {}
	if channels.is_empty():
		return 0.0
	var total := 0.0
	var count := 0
	for value_variant in channels.values():
		total += clampf(float(value_variant), 0.0, 1.0)
		count += 1
	if count <= 0:
		return 0.0
	return clampf(total / float(count), 0.0, 1.0)

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
