extends Node
class_name LocalAgentsBoidsBehaviorController

const _NATIVE_BRIDGE_CLASS_NAME: String = "LocalAgentsBoidsNativeBridge"
const _SHADER_BACKEND_CLASS_NAME: String = "LocalAgentsBoidsComputeBackend"
const _GPU_REQUIRED_ERROR: String = "GPU_REQUIRED"
const _NATIVE_REQUIRED_ERROR: String = "NATIVE_REQUIRED"
const _INVALID_RUNTIME_SETTINGS_ERROR: String = "INVALID_BOIDS_RUNTIME_SETTINGS"
const _INVALID_SOURCE_CONTRACT_ERROR: String = "INVALID_BOIDS_SOURCE_CONTRACT"
const BoidsComputeBackendScript = preload("res://addons/local_agents/simulation/BoidsComputeBackend.gd")

@export var enabled: bool = true
@export var boids_agent_source_path: NodePath = NodePath("")
@export var neighbor_radius: float = 3.0
@export var separation_radius: float = 1.2
@export var max_agents_considered: int = 24
@export var separation_weight: float = 1.75
@export var alignment_weight: float = 0.9
@export var cohesion_weight: float = 0.55
@export var intent_weight: float = 1.55
@export_range(0.0, 4.0, 0.01) var max_fly_climb_speed: float = 1.0
@export_range(0.0, 4.0, 0.01) var max_fly_sink_speed: float = 0.6
@export var fallback_max_speed: float = 2.8
@export var fallback_min_speed: float = 0.0

var _owner: Node = null
var _backend: Object = null
var _backend_ready: bool = false
var _shader_backend: Object = null
var _last_positions: Dictionary = {}
var _agent_source: Object = null
var _agent_source_params: Dictionary = {}
var _runtime_settings_source: Variant = null

func setup(owner: Node) -> void:
	_owner = owner
	_initialize_backend()
	_resolve_boid_agent_source()

func set_boids_agent_source(source: Variant) -> void:
	if source != null and is_instance_valid(source):
		_agent_source = source
	else:
		_agent_source = null

func set_runtime_settings_source(source: Variant) -> void:
	_runtime_settings_source = source

func step_mammals(agents: Array, delta: float) -> Dictionary:
	_resolve_boid_agent_source()
	if not enabled:
		return {
			"ok": false,
			"backend": "disabled",
			"applied_count": 0,
			"applied_agent_ids": [],
			"applied_to_all": false,
			"inputs": [],
		}
	if delta <= 0.0:
		return {
			"ok": false,
			"backend": "invalid_step",
			"error": "delta must be positive",
			"applied_count": 0,
			"applied_agent_ids": [],
		"applied_to_all": false,
		"inputs": [],
		}
	var inputs_result := _collect_agent_inputs(agents, delta)
	if not bool(inputs_result.get("ok", false)):
		return {
			"ok": false,
			"backend": String(inputs_result.get("backend", "agent_source")),
			"error": String(inputs_result.get("error", "")),
			"error_code": String(inputs_result.get("error_code", inputs_result.get("error", ""))),
			"error_detail": String(inputs_result.get("error_detail", "")),
			"applied_count": 0,
			"applied_agent_ids": [],
			"applied_to_all": false,
			"inputs": [],
			"backend_authority": String(inputs_result.get("backend_authority", "")),
			"scope_confirmation": String(inputs_result.get("scope_confirmation", "")),
		}
	var inputs := inputs_result.get("rows", []) as Array
	if inputs.is_empty():
		return {
			"ok": true,
			"backend": "noop",
			"error": "",
			"applied_count": 0,
			"applied_agent_ids": [],
			"applied_to_all": true,
			"inputs": inputs,
		}
	var runtime_result := _resolve_runtime_boid_params()
	if not bool(runtime_result.get("ok", false)):
		return {
			"ok": false,
			"backend": String(runtime_result.get("backend", "runtime_settings")),
			"error": String(runtime_result.get("error", "")),
			"error_code": String(runtime_result.get("error_code", runtime_result.get("error", ""))),
			"error_detail": String(runtime_result.get("error_detail", "")),
			"applied_count": 0,
			"applied_agent_ids": [],
			"applied_to_all": false,
			"inputs": inputs,
			"backend_authority": String(runtime_result.get("backend_authority", "")),
			"scope_confirmation": String(runtime_result.get("scope_confirmation", "")),
		}
	var runtime_params := runtime_result.get("params", {}) as Dictionary
	var dispatch_result := _dispatch_to_backend(inputs, delta, runtime_params)
	if not bool(dispatch_result.get("ok", false)):
		return {
			"ok": false,
			"backend": String(dispatch_result.get("backend", "unknown")),
			"error": String(dispatch_result.get("error", "")),
			"error_code": String(dispatch_result.get("error_code", dispatch_result.get("error", ""))),
			"error_detail": String(dispatch_result.get("error_detail", "")),
			"applied_count": 0,
			"applied_agent_ids": [],
			"applied_to_all": false,
			"inputs": inputs,
			"backend_authority": String(dispatch_result.get("backend_authority", "")),
			"scope_confirmation": String(dispatch_result.get("scope_confirmation", "")),
		}
	var outputs: Array = dispatch_result.get("rows", []) as Array
	var applied := _apply_outputs(agents, outputs, runtime_params)
	return {
		"ok": true,
		"backend": String(dispatch_result.get("backend", "gdscript")),
		"error": String(dispatch_result.get("error", "")),
		"error_code": String(dispatch_result.get("error_code", dispatch_result.get("error", ""))),
		"error_detail": String(dispatch_result.get("error_detail", "")),
		"backend_authority": String(dispatch_result.get("backend_authority", "")),
		"scope_confirmation": String(dispatch_result.get("scope_confirmation", "")),
		"applied_count": applied.size(),
		"applied_agent_ids": applied,
		"applied_to_all": applied.size() == agents.size(),
		"inputs": inputs,
	}

func _initialize_backend() -> void:
	if _backend_ready:
		return
	if ClassDB.class_exists(_NATIVE_BRIDGE_CLASS_NAME):
		var candidate := ClassDB.instantiate(_NATIVE_BRIDGE_CLASS_NAME)
		if candidate is Object:
			_backend = candidate
	if ClassDB.class_exists(_SHADER_BACKEND_CLASS_NAME):
		_shader_backend = BoidsComputeBackendScript.new()
	_backend_ready = true

func _dispatch_to_backend(inputs: Array, delta: float, runtime_params: Dictionary) -> Dictionary:
	var native_request := {
		"agent_count": inputs.size(),
		"workgroup_size": BoidsComputeBackendScript.WG_SIZE,
	}
	var shader_contract: Dictionary
	if _backend != null and _backend.has_method("can_execute_boids_step"):
		var contract_variant = _backend.can_execute_boids_step(inputs.size(), native_request)
		if contract_variant is Dictionary:
			shader_contract = contract_variant
		else:
			shader_contract = {
				"ok": false,
				"error_code": _NATIVE_REQUIRED_ERROR,
				"error_detail": "native contract is not a dictionary",
			}
	else:
		shader_contract = {"ok": true, "backend": "shader_compute", "backend_authority": "shader_authoritative"}

	var shader_capable := bool(shader_contract.get("ok", false))
	var error_code := String(shader_contract.get("error_code", String(shader_contract.get("error", "")))).strip_edges().to_upper()

	if shader_capable:
		var shader_result := _dispatch_to_shader(inputs, delta, shader_contract, runtime_params)
		shader_result["backend"] = String(shader_result.get("backend", "shader_compute"))
		return shader_result

	if error_code == _GPU_REQUIRED_ERROR:
		return {
			"ok": false,
			"backend": "shader_compute",
			"backend_authority": "shader_contract_required",
			"error": _GPU_REQUIRED_ERROR,
			"error_code": _GPU_REQUIRED_ERROR,
			"error_detail": String(shader_contract.get("error_detail", "GPU backend is required for boids execution")),
			"rows": [],
		}

	return _dispatch_to_native(inputs, delta, shader_contract, runtime_params)

func _collect_agent_inputs(agents: Array, delta: float) -> Dictionary:
	var normalized_delta := maxf(delta, 0.0001)
	var source_rows := _collect_agent_rows_from_source(agents, normalized_delta)
	if source_rows == null or not bool(source_rows.get("ok", false)):
		return source_rows
	var resolved_source_rows := source_rows.get("rows", []) as Array
	if not resolved_source_rows.is_empty() or _agent_source != null:
		return {
			"ok": true,
			"backend": "agent_source",
			"rows": resolved_source_rows,
			"inputs": resolved_source_rows,
		}

	var rows: Array = []
	for agent_variant in agents:
		if not (agent_variant is Node3D):
			continue
		var row := _collect_agent_row_fallback(agent_variant as Node3D, normalized_delta)
		if not row.is_empty():
			rows.append(row)
	return {
		"ok": true,
		"backend": "fallback",
		"rows": rows,
		"inputs": rows,
	}

func _collect_agent_rows_from_source(agents: Array, delta: float) -> Dictionary:
	if _agent_source == null or not is_instance_valid(_agent_source):
		return {
			"ok": true,
			"backend": "agent_source",
			"rows": [],
		}
	if not _agent_source.has_method("collect_boid_inputs"):
		_agent_source = null
		return {
			"ok": false,
			"backend": "agent_source",
			"backend_authority": "agent_source_contract",
			"error_code": _INVALID_SOURCE_CONTRACT_ERROR,
			"error": _INVALID_SOURCE_CONTRACT_ERROR,
			"error_detail": "boids agent source missing collect_boid_inputs",
			"rows": [],
		}
	var payload_variant = _agent_source.call("collect_boid_inputs", agents, delta)
	if not (payload_variant is Dictionary):
		return {
			"ok": false,
			"backend": "agent_source",
			"backend_authority": "agent_source_contract",
			"error_code": _INVALID_SOURCE_CONTRACT_ERROR,
			"error": _INVALID_SOURCE_CONTRACT_ERROR,
			"error_detail": "boids agent source returned invalid contract payload",
			"rows": [],
		}
	var payload := payload_variant as Dictionary
	var source_ok := bool(payload.get("ok", true))
	if not source_ok:
		return {
			"ok": false,
			"backend": "agent_source",
			"backend_authority": "agent_source_contract",
			"error_code": String(payload.get("error_code", _INVALID_SOURCE_CONTRACT_ERROR)),
			"error": String(payload.get("error", payload.get("error_code", _INVALID_SOURCE_CONTRACT_ERROR))),
			"error_detail": String(payload.get("error_detail", "boids agent source returned an invalid contract result")),
			"rows": [],
		}
	if bool(payload.get("enabled", true)) == false:
		_agent_source_params = {}
		return {
			"ok": true,
			"backend": "agent_source",
			"rows": [],
		}
	var source_params_variant = payload.get("params", {})
	if source_params_variant is Dictionary:
		_agent_source_params = source_params_variant
	elif source_params_variant != null:
		return {
			"ok": false,
			"backend": "agent_source",
			"backend_authority": "agent_source_contract",
			"error_code": _INVALID_SOURCE_CONTRACT_ERROR,
			"error": _INVALID_SOURCE_CONTRACT_ERROR,
			"error_detail": "boids agent source params must be a dictionary",
			"rows": [],
		}
	else:
		_agent_source_params = {}
	var rows_variant = payload.get("rows", [])
	if not (rows_variant is Array):
		return {
			"ok": false,
			"backend": "agent_source",
			"backend_authority": "agent_source_contract",
			"error_code": _INVALID_SOURCE_CONTRACT_ERROR,
			"error": _INVALID_SOURCE_CONTRACT_ERROR,
			"error_detail": "boids agent source rows must be an array",
			"rows": [],
		}
	var rows: Array = []
	for row_variant in rows_variant:
		if not (row_variant is Dictionary):
			continue
		var row = _coerce_source_row(row_variant as Dictionary)
		if row.is_empty():
			continue
		rows.append(row)
	return {
		"ok": true,
		"backend": "agent_source",
		"rows": rows,
	}

func _collect_agent_row_fallback(agent: Node3D, normalized_delta: float) -> Dictionary:
	var agent_id := _resolve_agent_id(agent)
	var position := agent.global_position
	var last_position_variant := _last_positions.get(agent_id)
	var last_position := position if last_position_variant == null else last_position_variant as Vector3
	var velocity := (position - last_position) / normalized_delta
	_last_positions[agent_id] = position
	var intent := Vector3.ZERO
	var speed_hint := _resolve_speed_hint(agent)
	if bool(agent.call("is_fleeing") if agent.has_method("is_fleeing") else false):
		if velocity.length_squared() > 0.0:
			intent = -velocity.normalized()
		if is_equal_approx(speed_hint, 0.0):
			speed_hint = _resolve_speed_hint(agent, "flee_speed")
	else:
		var has_food_target := _to_bool(agent.get("_has_food_target"))
		if has_food_target:
			var food_target_variant := agent.get("_food_target")
			if food_target_variant is Vector3:
				intent = food_target_variant as Vector3 - position
		if intent.length_squared() > 0.0:
			intent = intent.normalized()
			if is_equal_approx(speed_hint, 0.0):
				speed_hint = _resolve_speed_hint(agent)
	return {
		"agent_id": agent_id,
		"position": position,
		"velocity": velocity,
		"intent": intent,
		"speed_hint": speed_hint,
	}

func _dispatch_to_native(inputs: Array, delta: float, shader_contract: Dictionary, runtime_params: Dictionary) -> Dictionary:
	if _backend == null or not _backend.has_method("run_native_boids_step"):
		return {
			"ok": false,
			"backend": "native",
			"backend_authority": "native_bridge_missing",
			"error": _NATIVE_REQUIRED_ERROR,
			"error_code": _NATIVE_REQUIRED_ERROR,
			"error_detail": "native bridge unavailable for boids native execution",
			"rows": [],
		}

	var native_payload := {
		"agent_count": inputs.size(),
		"agents": inputs,
		"delta": delta,
		"requested_contract": shader_contract,
		"max_speed": _to_float(runtime_params.get("max_speed", fallback_max_speed), fallback_max_speed),
	}
	var native_result_variant = _backend.run_native_boids_step(native_payload)
	if native_result_variant is Dictionary:
		var native_result = native_result_variant
		var native_error := String(native_result.get("error_code", String(native_result.get("error", "")))).strip_edges().to_upper()
		var native_ok := bool(native_result.get("ok", false))
		var rows_variant = native_result.get("rows", [])
		var rows: Array = rows_variant if rows_variant is Array else []
		return {
			"ok": native_ok,
			"backend": String(native_result.get("backend", "native")),
			"backend_authority": String(native_result.get("backend_authority", "native_required")),
			"error": String(native_result.get("error", "")) if not native_ok else String(),
			"error_code": native_error if not native_ok else String(),
			"error_detail": String(native_result.get("error_detail", "")) if not native_ok else String(),
			"scope_confirmation": String(native_result.get("scope_confirmation", "")),
			"rows": rows,
		}

	return {
		"ok": false,
		"backend": "native",
		"backend_authority": "native_required",
		"error": _NATIVE_REQUIRED_ERROR,
		"error_code": _NATIVE_REQUIRED_ERROR,
		"error_detail": "Native boids execution payload is not a dictionary",
		"rows": [],
	}

func _dispatch_to_shader(inputs: Array, delta: float, contract: Dictionary, runtime_params: Dictionary) -> Dictionary:
	if _shader_backend == null or not _shader_backend.is_configured():
		_shader_backend = BoidsComputeBackendScript.new()
	if _shader_backend == null:
		return {
			"ok": false,
			"backend": "shader_compute",
			"backend_authority": "shader_unavailable",
			"error": _NATIVE_REQUIRED_ERROR,
			"error_code": _NATIVE_REQUIRED_ERROR,
			"error_detail": "Boids shader backend unavailable",
			"rows": [],
		}
	runtime_params = _coerce_runtime_boid_params(runtime_params.duplicate(true))
	var runtime_contract_validation := _validate_runtime_boid_contract(runtime_params)
	if not bool(runtime_contract_validation.get("ok", false)):
		return {
			"ok": false,
			"backend": "shader_compute",
			"backend_authority": "shader_runtime_contract",
			"error": String(runtime_contract_validation.get("error", _INVALID_RUNTIME_SETTINGS_ERROR)),
			"error_code": String(runtime_contract_validation.get("error_code", _INVALID_RUNTIME_SETTINGS_ERROR)),
			"error_detail": String(runtime_contract_validation.get("error_detail", "Shader runtime contract validation failed.")),
			"rows": [],
		}

	var shader_positions: PackedFloat32Array = PackedFloat32Array()
	var shader_velocities: PackedFloat32Array = PackedFloat32Array()
	var shader_target_intents: PackedFloat32Array = PackedFloat32Array()
	var shader_avoid_intents: PackedFloat32Array = PackedFloat32Array()
	var shader_world_surface: PackedInt32Array = PackedInt32Array()
	var shader_world_surface_width: int = 0
	var shader_world_surface_depth: int = 0
	var target_weight := clampf(_to_float(runtime_params.get("target_weight", _to_float(runtime_params.get("target_bias", intent_weight)))), 0.0, 1.0)
	var avoidance_weight := clampf(_to_float(runtime_params.get("avoidance_weight", _to_float(runtime_params.get("obstacle_avoidance_weight", 0.0)))), 0.0, 4.0)
	var world_avoid_weight_value := _to_float(runtime_params.get("world_avoid_weight", 0.0))
	if runtime_params.has("world_avoidance_weight"):
		world_avoid_weight_value = _to_float(runtime_params.get("world_avoidance_weight"))
	elif runtime_params.has("obstacle_avoidance_weight"):
		world_avoid_weight_value = _to_float(runtime_params.get("obstacle_avoidance_weight"))
	var world_avoid_weight := clampf(world_avoid_weight_value, 0.0, 4.0)
	var voxel_avoid_distance := maxf(0.0, _to_float(runtime_params.get("voxel_avoid_distance", 0.0)))
	if runtime_params.has("world_avoidance_distance"):
		voxel_avoid_distance = maxf(0.0, _to_float(runtime_params.get("world_avoidance_distance")))
	elif runtime_params.has("obstacle_avoidance_distance"):
		voxel_avoid_distance = maxf(0.0, _to_float(runtime_params.get("obstacle_avoidance_distance")))
	var agent_radius := maxf(0.01, _to_float(runtime_params.get("agent_radius", 0.7)))
	var ground_clearance := maxf(0.0, _to_float(runtime_params.get("ground_clearance", 1.0)))
	var default_fly_clearance := maxf(ground_clearance, 1.0)
	var fly_clearance := maxf(0.0, _to_float(runtime_params.get("fly_clearance", default_fly_clearance), default_fly_clearance))
	var max_fly_climb_speed := maxf(0.0, _to_float(runtime_params.get("max_fly_climb_speed", 0.0)))
	var max_fly_sink_speed := maxf(0.0, _to_float(runtime_params.get("max_fly_sink_speed", 0.0)))
	var max_terrain_step := maxf(0.0, _to_float(runtime_params.get("max_terrain_step", 0.0)))
	var max_altitude := maxf(0.0, _to_float(runtime_params.get("max_altitude", 0.0)))
	var seek_high_ground := _to_bool(runtime_params.get("seek_high_ground", _to_bool(runtime_params.get("fly_seek_high_ground", false))))
	var orbit_radius := maxf(0.0, _to_float(runtime_params.get("orbit_radius", 0.0)))
	var orbit_enabled := _to_bool(runtime_params.get("orbit_enabled", true))
	var orbit_rate := 0.0
	if runtime_params.has("orbit_rate"):
		orbit_rate = _to_float(runtime_params.get("orbit_rate"), 0.0)
	elif runtime_params.has("flock_circling_weight"):
		orbit_rate = _to_float(runtime_params.get("flock_circling_weight"), 0.0)
	elif runtime_params.has("orbit_speed"):
		orbit_rate = _to_float(runtime_params.get("orbit_speed"), 0.0)
	if not orbit_enabled:
		orbit_rate = 0.0
	orbit_rate = clampf(orbit_rate, 0.0, 4.0)
	var altitude_seek_weight := clampf(_to_float(runtime_params.get("altitude_seek_weight", 0.0)), 0.0, 4.0)
	var altitude_seek_target := maxf(0.0, _to_float(runtime_params.get("altitude_seek_target", 0.0)))
	var runtime_neighbor_radius := maxf(0.0001, _to_float(runtime_params.get("neighbor_radius", neighbor_radius), neighbor_radius))
	var runtime_separation_radius := maxf(0.0001, _to_float(runtime_params.get("separation_radius", separation_radius), separation_radius))
	var runtime_separation_weight := clampf(_to_float(runtime_params.get("separation_weight", separation_weight)), 0.0, 4.0)
	var runtime_alignment_weight := clampf(_to_float(runtime_params.get("alignment_weight", alignment_weight)), 0.0, 4.0)
	var runtime_cohesion_weight := clampf(_to_float(runtime_params.get("cohesion_weight", cohesion_weight)), 0.0, 4.0)
	var runtime_max_speed := maxf(0.0001, _to_float(runtime_params.get("max_speed", fallback_max_speed), fallback_max_speed))
	var runtime_max_turn_rate := maxf(0.0001, _to_float(runtime_params.get("max_turn_rate", 1.0), 1.0))
	var world_bounds_radius_origin := maxf(0.0, _to_float(runtime_params.get("max_distance_from_origin", 0.0), 0.0))
	var world_bounds_radius_anchor := maxf(0.0, _to_float(runtime_params.get("max_distance_from_anchor", 0.0), 0.0))
	var world_bounds_radius := maxf(world_bounds_radius_origin, world_bounds_radius_anchor)
	var runtime_flock_center := Vector3.ZERO
	var runtime_flock_velocity := Vector3.ZERO
	var has_runtime_flock_reference := false
	var requires_world_surface := world_avoid_weight > 0.0001 or voxel_avoid_distance > 0.0001 or max_terrain_step > 0.0001 or altitude_seek_weight > 0.0001 or bool(seek_high_ground)
	if requires_world_surface:
		var world_contract_variant = _resolve_world_surface_contract()
		if not bool(world_contract_variant.get("ok", false)):
			var world_error_code := String(world_contract_variant.get("error_code", _GPU_REQUIRED_ERROR))
			return {
				"ok": false,
				"backend": "shader_compute",
				"backend_authority": "shader_world_contract",
				"error": world_error_code,
				"error_code": world_error_code,
				"error_detail": String(world_contract_variant.get("error_detail", "Boids world surface contract is not available")),
				"rows": [],
			}
		shader_world_surface_width = int(world_contract_variant.get("world_surface_width", 0))
		shader_world_surface_depth = int(world_contract_variant.get("world_surface_depth", 0))
		var surface_buffer_variant = world_contract_variant.get("world_surface_height", PackedInt32Array())
		if surface_buffer_variant is PackedInt32Array:
			shader_world_surface = surface_buffer_variant
		else:
			return {
				"ok": false,
				"backend": "shader_compute",
				"backend_authority": "shader_world_contract",
				"error": _GPU_REQUIRED_ERROR,
				"error_code": _GPU_REQUIRED_ERROR,
				"error_detail": "World surface contract did not return a valid height buffer.",
				"rows": [],
			}

	for row_variant in inputs:
		if not (row_variant is Dictionary):
			continue
		var row := row_variant as Dictionary
		var position := _to_vector3(row.get("position", Vector3.ZERO))
		var velocity := _to_vector3(row.get("velocity", Vector3.ZERO))
		var target_intent := _to_vector3(row.get("target_goal", row.get("intent", Vector3.ZERO)))
		var row_target_active := row.get("target_active", row.get("target_weight", 1.0))
		var target_intent_active := clampf(_to_float(row_target_active, 1.0), 0.0, 1.0)
		target_intent_active *= clampf(target_weight, 0.0, 1.0)
		var avoid_intent := _to_vector3(row.get("avoidance_goal", Vector3.ZERO))
		var avoid_active := clampf(_to_float(row.get("avoidance_active", row.get("avoidance_weight", row.get("obstacle_weight", 0.0)))), 0.0, 1.0)
		if not has_runtime_flock_reference:
			runtime_flock_center = _to_vector3(row.get("flock_center", Vector3.ZERO))
			runtime_flock_velocity = _to_vector3(row.get("flock_velocity", Vector3.ZERO))
			has_runtime_flock_reference = true

		shader_positions.append(position.x)
		shader_positions.append(position.y)
		shader_positions.append(position.z)
		shader_positions.append(1.0)
		shader_velocities.append(velocity.x)
		shader_velocities.append(velocity.y)
		shader_velocities.append(velocity.z)
		shader_velocities.append(1.0)
		shader_target_intents.append(target_intent.x)
		shader_target_intents.append(target_intent.y)
		shader_target_intents.append(target_intent.z)
		shader_target_intents.append(target_intent_active)
		shader_avoid_intents.append(avoid_intent.x)
		shader_avoid_intents.append(avoid_intent.y)
		shader_avoid_intents.append(avoid_intent.z)
		shader_avoid_intents.append(avoid_active)
	if not _shader_backend.configure(shader_positions, shader_velocities, shader_target_intents, shader_avoid_intents, shader_world_surface, shader_world_surface_width, shader_world_surface_depth):
		return {
			"ok": false,
			"backend": "shader_compute",
			"backend_authority": "shader_compute",
			"error": _GPU_REQUIRED_ERROR,
			"error_code": _GPU_REQUIRED_ERROR,
			"error_detail": "boids shader backend could not configure",
			"rows": [],
		}

	var step_result = _shader_backend.step(
		delta,
		shader_target_intents,
		shader_avoid_intents,
		runtime_separation_weight,
		runtime_alignment_weight,
		runtime_cohesion_weight,
		target_weight,
		avoidance_weight,
		runtime_neighbor_radius,
		runtime_separation_radius,
		runtime_max_speed,
		runtime_max_turn_rate,
		world_bounds_radius,
		voxel_avoid_distance,
		world_avoid_weight,
		agent_radius,
		ground_clearance,
		fly_clearance,
		max_terrain_step,
		max_altitude,
		1.0 if seek_high_ground else 0.0,
		orbit_radius,
		orbit_rate,
		altitude_seek_weight,
		altitude_seek_target,
		runtime_flock_center.x,
		runtime_flock_center.y,
		runtime_flock_center.z,
		runtime_flock_velocity.x,
		runtime_flock_velocity.y,
		runtime_flock_velocity.z,
		max_fly_climb_speed,
		max_fly_sink_speed
	)
	if not (step_result is Dictionary):
		return {
			"ok": false,
			"backend": "shader_compute",
			"backend_authority": "shader_authoritative",
			"error": _NATIVE_REQUIRED_ERROR,
			"error_code": _NATIVE_REQUIRED_ERROR,
			"error_detail": "Invalid shader step result",
			"rows": [],
		}
	var step_ok := bool(step_result.get("ok", true))
	if not step_ok:
		return {
			"ok": false,
			"backend": "shader_compute",
			"backend_authority": "shader_authoritative",
			"error": String(step_result.get("error", "")),
			"error_code": String(step_result.get("error_code", _GPU_REQUIRED_ERROR)),
			"error_detail": String(step_result.get("error_detail", "Shader step setup validation failed")),
			"rows": [],
		}
	var step_payload = step_result as Dictionary
	var out_velocities = step_payload.get("velocities", PackedFloat32Array())
	if not (out_velocities is PackedFloat32Array):
		return {
			"ok": false,
			"backend": "shader_compute",
			"backend_authority": "shader_authoritative",
			"error": _NATIVE_REQUIRED_ERROR,
			"error_code": _NATIVE_REQUIRED_ERROR,
			"error_detail": "Shader step did not return velocity payload",
			"scope_confirmation": String(contract.get("scope_confirmation", "")),
			"rows": [],
		}

	var output_count := int(out_velocities.size() / 4)
	if output_count != inputs.size():
		return {
			"ok": false,
			"backend": "shader_compute",
			"backend_authority": "shader_authoritative",
			"error": _NATIVE_REQUIRED_ERROR,
			"error_code": _NATIVE_REQUIRED_ERROR,
			"error_detail": "Shader step returned incomplete velocity payload",
			"scope_confirmation": String(contract.get("scope_confirmation", "")),
			"rows": [],
		}

	var output_rows: Array = []
	var runtime_min_speed := maxf(0.0, _to_float(runtime_params.get("fallback_min_speed", fallback_min_speed), fallback_min_speed))
	var runtime_max_speed_out := maxf(runtime_min_speed, _to_float(runtime_params.get("max_speed", fallback_max_speed), fallback_max_speed))
	for i in range(min(output_count, inputs.size())):
		var row_variant = inputs[i]
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var base_speed := float(row.get("speed_hint", fallback_max_speed))
		var vx := float(out_velocities[i * 4])
		var vy := float(out_velocities[i * 4 + 1])
		var vz := float(out_velocities[i * 4 + 2])
		var velocity = Vector3(vx, vy, vz)
		var row_speed := maxf(velocity.length(), base_speed)
		output_rows.append({
			"agent_id": row.get("agent_id", ""),
			"velocity": velocity,
			"speed": clampf(row_speed, runtime_min_speed, runtime_max_speed_out),
			"intent": row.get("intent", Vector3.ZERO),
			"delta": delta,
		})

	return {
		"ok": true,
		"backend": "shader_compute",
		"backend_authority": "shader_authoritative",
		"scope_confirmation": "Shader path authoritative: agent_count=%d, max_supported_agents=%d, required_workgroups=%d." %
			[inputs.size(), int(contract.get("max_supported_agents", 0)), int(contract.get("required_workgroups", 0))],
		"rows": output_rows,
	}

func _apply_outputs(agents: Array, outputs: Array, runtime_params: Dictionary = {}) -> Array:
	var runtime_min_speed := maxf(0.0, _to_float(runtime_params.get("fallback_min_speed", fallback_min_speed), fallback_min_speed))
	var runtime_max_speed := maxf(runtime_min_speed, _to_float(runtime_params.get("max_speed", fallback_max_speed), fallback_max_speed))
	var output_by_id: Dictionary = {}
	for output_variant in outputs:
		if not (output_variant is Dictionary):
			continue
		var output: Dictionary = output_variant
		var agent_id := output.get("agent_id", "")
		if not agent_id is String or String(agent_id).is_empty():
			continue
		var clamped_speed := clampf(float(output.get("speed", 0.0)), runtime_min_speed, runtime_max_speed)
		output["speed"] = clamped_speed
		output_by_id[String(agent_id)] = output
	var applied_ids: Array = []
	for agent_variant in agents:
		if not (agent_variant is Node):
			continue
		var agent: Node = agent_variant
		var agent_id := _resolve_agent_id(agent)
		var output_variant = output_by_id.get(agent_id, null)
		if output_variant == null or not (output_variant is Dictionary):
			continue
		var output := output_variant as Dictionary
		if agent.has_method("apply_mammal_behavior_output"):
			agent.call("apply_mammal_behavior_output", output.get("velocity", Vector3.ZERO), output.get("speed", 0.0), output.get("intent", Vector3.ZERO))
			applied_ids.append(agent_id)
		else:
			var velocity = output.get("velocity", Vector3.ZERO) as Vector3
			var speed = float(output.get("speed", 0.0))
			if agent is Node3D and velocity.length_squared() > 0.0 and speed > 0.0:
				agent.global_position += velocity.normalized() * speed * float(output.get("delta", 0.0))
				applied_ids.append(agent_id)
	return applied_ids

func _resolve_runtime_boid_params() -> Dictionary:
	var params: Dictionary = {
		"can_walk": true,
		"can_fly": false,
		"walk_speed": 1.0,
		"run_speed": 2.8,
		"neighbor_radius": neighbor_radius,
		"separation_radius": separation_radius,
		"separation_weight": separation_weight,
		"alignment_weight": alignment_weight,
		"cohesion_weight": cohesion_weight,
		"target_bias": intent_weight,
		"flock_bias": 1.0,
		"obstacle_avoidance_weight": 0.0,
		"obstacle_avoidance_distance": 0.0,
		"world_avoidance_weight": 0.0,
		"world_avoidance_distance": 0.0,
		"altitude_seek_weight": 0.0,
		"altitude_seek_target": 0.0,
		"max_turn_rate": 1.0,
		"max_speed": fallback_max_speed,
		"fallback_min_speed": fallback_min_speed,
		"max_distance_from_origin": 0.0,
		"max_distance_from_anchor": 0.0,
		"agent_radius": 0.35,
		"ground_clearance": 0.25,
		"fly_clearance": 1.0,
		"voxel_avoid_distance": 2.5,
		"world_avoid_weight": 0.0,
		"max_terrain_slope": 45.0,
		"max_terrain_step": 0.0,
		"max_altitude": 128.0,
		"seek_high_ground": true,
		"orbit_enabled": true,
		"orbit_rate": 0.0,
		"orbit_radius": 0.0,
		"ground_height": 0.0,
		"altitude": 0.0,
		"fly_altitude_preference": 0.0,
		"spawn_height": 0.0,
		"initial_altitude": 0.0,
		"flock_circling_weight": 0.0,
		"max_fly_climb_speed": max_fly_climb_speed,
		"max_fly_sink_speed": max_fly_sink_speed,
	}
	for key in _agent_source_params.keys():
		params[key] = _agent_source_params.get(key)
	if not params.has("target_bias") and params.has("target_weight"):
		params["target_bias"] = _to_float(params.get("target_weight"), intent_weight)
	if not params.has("target_weight") and params.has("target_bias"):
		params["target_weight"] = params["target_bias"]
	if not params.has("obstacle_avoidance_weight") and params.has("obstacle_weight"):
		params["obstacle_avoidance_weight"] = _to_float(params.get("obstacle_weight"), 0.0)
	var resolved_world_avoid_weight := 0.0
	if params.has("world_avoid_weight"):
		resolved_world_avoid_weight = _to_float(params.get("world_avoid_weight"), 0.0)
	elif params.has("world_avoidance_weight"):
		resolved_world_avoid_weight = _to_float(params.get("world_avoidance_weight"), 0.0)
	elif params.has("obstacle_avoidance_weight"):
		resolved_world_avoid_weight = _to_float(params.get("obstacle_avoidance_weight"), 0.0)
	params["world_avoid_weight"] = clampf(resolved_world_avoid_weight, 0.0, 4.0)
	params["world_avoidance_weight"] = params["world_avoid_weight"]
	params["obstacle_avoidance_weight"] = params["world_avoid_weight"]

	var resolved_avoid_distance := 0.0
	if params.has("voxel_avoid_distance"):
		resolved_avoid_distance = _to_float(params.get("voxel_avoid_distance"), 0.0)
	elif params.has("world_avoidance_distance"):
		resolved_avoid_distance = _to_float(params.get("world_avoidance_distance"), 0.0)
	elif params.has("obstacle_avoidance_distance"):
		resolved_avoid_distance = _to_float(params.get("obstacle_avoidance_distance"), 0.0)
	params["voxel_avoid_distance"] = maxf(0.0, resolved_avoid_distance)
	params["world_avoidance_distance"] = params["voxel_avoid_distance"]
	params["obstacle_avoidance_distance"] = params["voxel_avoid_distance"]

	var seek_high_ground := _to_bool(params.get("seek_high_ground", false))
	if not params.has("seek_high_ground") and params.has("fly_seek_high_ground"):
		seek_high_ground = _to_bool(params.get("fly_seek_high_ground", false))
	params["seek_high_ground"] = seek_high_ground
	params["altitude_seek_weight"] = clampf(_to_float(params.get("altitude_seek_weight", 0.5 if seek_high_ground else 0.0)), 0.0, 4.0)
	var altitude_seek_fallback := maxf(
		maxf(
			_to_float(params.get("altitude", 0.0), 0.0),
			_to_float(params.get("fly_altitude_preference", 0.0), 0.0)
		),
		maxf(
			_to_float(params.get("spawn_height", 0.0), 0.0),
			_to_float(params.get("initial_altitude", 0.0), 0.0)
		)
	)
	params["altitude_seek_target"] = maxf(
		0.0,
		_to_float(params.get("altitude_seek_target", altitude_seek_fallback), 0.0)
	)
	var orbit_enabled := _to_bool(params.get("orbit_enabled", true))
	params["orbit_enabled"] = orbit_enabled
	params["orbit_radius"] = maxf(0.0, _to_float(params.get("orbit_radius", 0.0)))
	var orbit_rate := 0.0
	if params.has("orbit_rate"):
		orbit_rate = _to_float(params.get("orbit_rate"), 0.0)
	elif params.has("flock_circling_weight"):
		orbit_rate = _to_float(params.get("flock_circling_weight"), 0.0)
	else:
		orbit_rate = _to_float(params.get("orbit_speed", 0.0), 0.0)
	if not orbit_enabled:
		orbit_rate = 0.0
	params["orbit_rate"] = clampf(orbit_rate, 0.0, 4.0)
	params["flock_circling_weight"] = params["orbit_rate"]
	var resolved_terrain_step := 0.0
	if params.has("max_terrain_step"):
		resolved_terrain_step = _to_float(params.get("max_terrain_step"), 0.0)
	elif params.has("max_terrain_slope"):
		resolved_terrain_step = _to_float(params.get("max_terrain_slope", 0.0), 0.0)
	params["max_terrain_step"] = maxf(0.0, resolved_terrain_step)
	if not params.has("max_fly_climb_speed"):
		params["max_fly_climb_speed"] = max_fly_climb_speed
	if not params.has("max_fly_sink_speed"):
		params["max_fly_sink_speed"] = max_fly_sink_speed

	params = _coerce_runtime_boid_params(params)
	var contract_validation := _validate_runtime_boid_contract(params)
	if not bool(contract_validation.get("ok", false)):
		return contract_validation
	return {
		"ok": true,
		"backend": "runtime_settings",
		"backend_authority": "boids_runtime_contract",
		"scope_confirmation": "Boids runtime contract resolved.",
		"params": params,
	}

func _coerce_runtime_boid_params(raw: Dictionary) -> Dictionary:
	var params := raw.duplicate(true)
	params["can_walk"] = _to_bool(params.get("can_walk", true))
	params["can_fly"] = _to_bool(params.get("can_fly", false))
	params["orbit_enabled"] = _to_bool(params.get("orbit_enabled", true))
	var seek_high_ground_fallback := _to_bool(params.get("fly_seek_high_ground", false))
	params["seek_high_ground"] = _to_bool(params.get("seek_high_ground", seek_high_ground_fallback))

	params["walk_speed"] = maxf(0.0, _to_float(params.get("walk_speed", 1.0)))
	params["run_speed"] = maxf(0.0, _to_float(params.get("run_speed", 2.8)))
	params["max_speed"] = clampf(_to_float(params.get("max_speed", fallback_max_speed)), 0.0, 64.0)
	params["fallback_min_speed"] = maxf(0.0, _to_float(params.get("fallback_min_speed", fallback_min_speed)))
	params["max_turn_rate"] = clampf(_to_float(params.get("max_turn_rate", 1.0)), 0.0001, 16.0)
	params["neighbor_radius"] = maxf(0.0001, _to_float(params.get("neighbor_radius", neighbor_radius)))
	params["separation_radius"] = maxf(0.0001, _to_float(params.get("separation_radius", separation_radius)))
	params["separation_weight"] = clampf(_to_float(params.get("separation_weight", separation_weight)), 0.0, 4.0)
	params["alignment_weight"] = clampf(_to_float(params.get("alignment_weight", alignment_weight)), 0.0, 4.0)
	params["cohesion_weight"] = clampf(_to_float(params.get("cohesion_weight", cohesion_weight)), 0.0, 4.0)
	var target_weight_value := _to_float(params.get("target_weight", _to_float(params.get("target_bias", intent_weight))))
	params["target_weight"] = clampf(target_weight_value, 0.0, 1.0)
	var target_bias_value := _to_float(params.get("target_bias", params.get("target_weight", intent_weight)))
	params["target_bias"] = clampf(target_bias_value, 0.0, 4.0)
	params["flock_bias"] = clampf(_to_float(params.get("flock_bias", 1.0)), 0.0, 4.0)

	var resolved_world_avoid_weight := 0.0
	if params.has("world_avoid_weight"):
		resolved_world_avoid_weight = _to_float(params.get("world_avoid_weight"), 0.0)
	elif params.has("world_avoidance_weight"):
		resolved_world_avoid_weight = _to_float(params.get("world_avoidance_weight"), 0.0)
	elif params.has("obstacle_avoidance_weight"):
		resolved_world_avoid_weight = _to_float(params.get("obstacle_avoidance_weight"), 0.0)
	params["world_avoid_weight"] = clampf(resolved_world_avoid_weight, 0.0, 4.0)
	params["world_avoidance_weight"] = params["world_avoid_weight"]

	var resolved_avoid_distance := 0.0
	if params.has("voxel_avoid_distance"):
		resolved_avoid_distance = _to_float(params.get("voxel_avoid_distance"), 0.0)
	elif params.has("world_avoidance_distance"):
		resolved_avoid_distance = _to_float(params.get("world_avoidance_distance"), 0.0)
	elif params.has("obstacle_avoidance_distance"):
		resolved_avoid_distance = _to_float(params.get("obstacle_avoidance_distance"), 0.0)
	params["voxel_avoid_distance"] = maxf(0.0, resolved_avoid_distance)
	params["world_avoidance_distance"] = params["voxel_avoid_distance"]
	params["obstacle_avoidance_distance"] = params["voxel_avoid_distance"]
	params["obstacle_avoidance_weight"] = params["world_avoid_weight"]

	params["max_terrain_slope"] = clampf(_to_float(params.get("max_terrain_slope", 45.0)), 0.0, 90.0)
	params["max_terrain_step"] = maxf(0.0, _to_float(params.get("max_terrain_step", params.get("max_terrain_slope", 0.0))))
	params["max_altitude"] = maxf(0.0, _to_float(params.get("max_altitude", 128.0)))
	params["max_distance_from_origin"] = maxf(0.0, _to_float(params.get("max_distance_from_origin", 0.0)))
	params["max_distance_from_anchor"] = maxf(0.0, _to_float(params.get("max_distance_from_anchor", 0.0)))
	params["agent_radius"] = clampf(_to_float(params.get("agent_radius", 0.35)), 0.05, 2.0)
	params["ground_clearance"] = maxf(0.0, _to_float(params.get("ground_clearance", 0.25)))
	params["fly_clearance"] = maxf(
		params["ground_clearance"],
		_to_float(params.get("fly_clearance", params["ground_clearance"]))
	)
	params["max_fly_climb_speed"] = maxf(0.0, _to_float(params.get("max_fly_climb_speed", max_fly_climb_speed)))
	params["max_fly_sink_speed"] = maxf(0.0, _to_float(params.get("max_fly_sink_speed", max_fly_sink_speed)))
	params["altitude_seek_weight"] = clampf(_to_float(params.get("altitude_seek_weight", 0.5 if params["seek_high_ground"] else 0.0)), 0.0, 4.0)
	params["altitude_seek_target"] = maxf(0.0, _to_float(params.get("altitude_seek_target", 0.0)))

	var orbit_rate := 0.0
	if params.has("orbit_rate"):
		orbit_rate = _to_float(params.get("orbit_rate"), 0.0)
	elif params.has("flock_circling_weight"):
		orbit_rate = _to_float(params.get("flock_circling_weight"), 0.0)
	elif params.has("orbit_speed"):
		orbit_rate = _to_float(params.get("orbit_speed"), 0.0)
	if not params["orbit_enabled"]:
		orbit_rate = 0.0
	params["orbit_rate"] = clampf(orbit_rate, 0.0, 4.0)
	params["orbit_radius"] = maxf(0.0, _to_float(params.get("orbit_radius", 0.0)))
	params["flock_circling_weight"] = params["orbit_rate"]
	params["flock_center"] = _to_vector3(params.get("flock_center", Vector3.ZERO))
	params["flock_velocity"] = _to_vector3(params.get("flock_velocity", Vector3.ZERO))
	params["ground_height"] = maxf(0.0, _to_float(params.get("ground_height", 0.0)))
	params["altitude"] = maxf(0.0, _to_float(params.get("altitude", 0.0)))
	params["spawn_height"] = maxf(0.0, _to_float(params.get("spawn_height", 0.0)))
	params["initial_altitude"] = maxf(0.0, _to_float(params.get("initial_altitude", 0.0)))
	params["fly_altitude_preference"] = maxf(0.0, _to_float(params.get("fly_altitude_preference", 0.0)))
	return params

func _validate_runtime_boid_contract(params: Dictionary) -> Dictionary:
	var errors: Array = []
	if not _is_finite_float(params.get("agent_radius", 0.0)):
		errors.append("agent_radius must be a finite non-negative number.")
	if not _is_finite_float(params.get("ground_clearance", 0.0)):
		errors.append("ground_clearance must be a finite non-negative number.")
	if not _is_finite_float(params.get("fly_clearance", 0.0)):
		errors.append("fly_clearance must be a finite non-negative number.")
	if not _is_finite_float(params.get("voxel_avoid_distance", 0.0)):
		errors.append("voxel_avoid_distance must be a finite non-negative number.")
	if not _is_finite_float(params.get("max_terrain_step", 0.0)):
		errors.append("max_terrain_step must be a finite non-negative number.")
	if not _is_finite_float(params.get("max_terrain_slope", 0.0)) or float(params.get("max_terrain_slope", 0.0)) > 90.0:
		errors.append("max_terrain_slope must be a finite number in [0, 90].")
	if not _is_finite_float(params.get("max_altitude", 0.0)):
		errors.append("max_altitude must be a finite non-negative number.")
	if not (params.get("can_walk", true) is bool):
		errors.append("can_walk must be boolean.")
	if not (params.get("can_fly", false) is bool):
		errors.append("can_fly must be boolean.")
	if not bool(params.get("can_walk", true)) and not bool(params.get("can_fly", false)):
		errors.append("At least one movement mode must be enabled.")
	if not _is_finite_float(params.get("walk_speed", 0.0)):
		errors.append("walk_speed must be a finite non-negative number.")
	if not _is_finite_float(params.get("run_speed", 0.0)):
		errors.append("run_speed must be a finite non-negative number.")
	if not _is_finite_float(params.get("max_distance_from_anchor", 0.0)):
		errors.append("max_distance_from_anchor must be a finite non-negative number.")
	if not _is_finite_float(params.get("max_distance_from_origin", 0.0)):
		errors.append("max_distance_from_origin must be a finite non-negative number.")
	if not _is_finite_float(params.get("neighbor_radius", 0.0)):
		errors.append("neighbor_radius must be a finite non-negative number.")
	if not _is_finite_float(params.get("separation_radius", 0.0)):
		errors.append("separation_radius must be a finite non-negative number.")
	if not _is_finite_float(params.get("world_avoid_weight", 0.0)) or float(params.get("world_avoid_weight", 0.0)) > 4.0:
		errors.append("world_avoid_weight must be a finite number in [0, 4].")
	if not _is_finite_float(params.get("orbit_radius", 0.0)):
		errors.append("orbit_radius must be a finite non-negative number.")
	if not _is_finite_float(params.get("orbit_rate", 0.0)) or float(params.get("orbit_rate", 0.0)) > 4.0:
		errors.append("orbit_rate must be a finite number in [0, 4].")
	if not (params.get("seek_high_ground", false) is bool):
		errors.append("seek_high_ground must be a boolean.")
	if not (params.get("orbit_enabled", true) is bool):
		errors.append("orbit_enabled must be a boolean.")
	if not _is_finite_float(params.get("max_speed", 0.0)) or float(params.get("max_speed", 0.0)) > 64.0:
		errors.append("max_speed must be a finite number in [0, 64].")
	if not _is_finite_float(params.get("max_turn_rate", 0.0001)) or float(params.get("max_turn_rate", 0.0001)) > 16.0:
		errors.append("max_turn_rate must be a finite number in [0.0001, 16].")
	if not _is_finite_float(params.get("max_fly_climb_speed", 0.0)):
		errors.append("max_fly_climb_speed must be a finite non-negative number.")
	if not _is_finite_float(params.get("max_fly_sink_speed", 0.0)):
		errors.append("max_fly_sink_speed must be a finite non-negative number.")
	if not errors.is_empty():
		return {
			"ok": false,
			"backend": "runtime_settings",
			"backend_authority": "boids_runtime_contract",
			"error": _INVALID_RUNTIME_SETTINGS_ERROR,
			"error_code": _INVALID_RUNTIME_SETTINGS_ERROR,
			"error_detail": ", ".join(errors),
			"scope_confirmation": "Boids runtime contract validation failed.",
			"params": {},
		}
	return { "ok": true }

func _resolve_world_surface_contract() -> Dictionary:
	var snapshot := _resolve_runtime_generation_snapshot()
	if snapshot.is_empty():
		return {
			"ok": false,
			"error_code": _GPU_REQUIRED_ERROR,
			"error": _GPU_REQUIRED_ERROR,
			"error_detail": "Runtime generation snapshot missing world surface metadata.",
			"backend_authority": "shader_world_contract",
		}
	var world_surface_width := int(snapshot.get("world_surface_width", snapshot.get("width", 0)))
	var world_surface_depth := int(snapshot.get("world_surface_depth", snapshot.get("height", 0)))
	if world_surface_width <= 0 and snapshot.has("voxel_world"):
		var voxel_world_variant = snapshot.get("voxel_world")
		if voxel_world_variant is Dictionary:
			var voxel_world := voxel_world_variant as Dictionary
			world_surface_width = int(voxel_world.get("width", 0))
			world_surface_depth = int(voxel_world.get("depth", 0))
	if world_surface_width <= 0:
		return {
			"ok": false,
			"error_code": _GPU_REQUIRED_ERROR,
			"error": _GPU_REQUIRED_ERROR,
			"error_detail": "Runtime world surface width is missing or invalid.",
			"backend_authority": "shader_world_contract",
		}
	if world_surface_depth <= 0:
		return {
			"ok": false,
			"error_code": _GPU_REQUIRED_ERROR,
			"error": _GPU_REQUIRED_ERROR,
			"error_detail": "Runtime world surface depth is missing or invalid.",
			"backend_authority": "shader_world_contract",
		}
	var expected_count := world_surface_width * world_surface_depth

	var world_surface_height = _coerce_world_surface_buffer(snapshot.get("world_surface_height", PackedInt32Array()))
	if world_surface_height.is_empty():
		return {
			"ok": false,
			"error_code": _GPU_REQUIRED_ERROR,
			"error": _GPU_REQUIRED_ERROR,
			"error_detail": "Runtime world surface height buffer is missing or empty.",
			"backend_authority": "shader_world_contract",
		}

	if world_surface_height.size() != expected_count:
		return {
			"ok": false,
			"error_code": _GPU_REQUIRED_ERROR,
			"error": _GPU_REQUIRED_ERROR,
			"error_detail": "Runtime world surface buffer size does not match configured surface dimensions.",
			"backend_authority": "shader_world_contract",
		}
	return {
		"ok": true,
		"world_surface_width": world_surface_width,
		"world_surface_depth": world_surface_depth,
		"world_surface_height": world_surface_height,
	}

func _resolve_runtime_generation_snapshot() -> Dictionary:
	if _runtime_settings_source == null:
		return {}
	if _runtime_settings_source is Dictionary:
		var source_dict := _runtime_settings_source as Dictionary
		if source_dict.get("_boids_settings_source_invalid", false):
			return {}
		var dict_snapshot_variant = source_dict.get("generation_snapshot", null)
		if dict_snapshot_variant is Dictionary:
			return dict_snapshot_variant
	var source := _runtime_settings_source
	if source is Object and is_instance_valid(source):
		if source.has_method("get_generation_snapshot"):
			var snapshot_variant = source.call("get_generation_snapshot")
			if snapshot_variant is Dictionary:
				return snapshot_variant
	return {}

func _coerce_world_surface_buffer(value: Variant) -> PackedInt32Array:
	if value is PackedInt32Array:
		return value as PackedInt32Array
	if not (value is Array):
		return PackedInt32Array()
	var source_array := value as Array
	var out := PackedInt32Array()
	out.resize(source_array.size())
	for i in range(source_array.size()):
		var source_value = source_array[i]
		if source_value is int:
			out[i] = source_value
		elif source_value is float:
			out[i] = int(source_value)
	return out

func _resolve_boid_agent_source() -> void:
	if boids_agent_source_path != NodePath("") and is_instance_valid(_owner):
		var direct_source = (_owner as Node).get_node_or_null(boids_agent_source_path)
		if direct_source != null and _is_boid_agent_source(direct_source):
			_agent_source = direct_source
			return
	if _agent_source != null and is_instance_valid(_agent_source) and _is_boid_agent_source(_agent_source):
		return
	if not is_instance_valid(_owner):
		_agent_source = null
		return
	_agent_source = null
	if (_owner as Node).get_tree() == null:
		return
	for source_candidate in (_owner as Node).get_tree().get_nodes_in_group("boids_agent_source"):
		if source_candidate is Object and is_instance_valid(source_candidate as Object) and _is_boid_agent_source(source_candidate):
			_agent_source = source_candidate
			return

func _is_boid_agent_source(candidate: Variant) -> bool:
	if not (candidate is Object):
		return false
	if not is_instance_valid(candidate):
		return false
	return candidate.has_method("collect_boid_inputs")

func _coerce_source_row(row: Dictionary) -> Dictionary:
	if row.is_empty():
		return {}
	var agent_id := _coerce_string(row.get("agent_id", ""))
	if agent_id.is_empty():
		return {}
	var position := _to_vector3(row.get("position", Vector3.ZERO))
	var velocity := _to_vector3(row.get("velocity", Vector3.ZERO))
	var intent := _to_vector3(row.get("intent", Vector3.ZERO))
	var out_row := row.duplicate(true)
	out_row["agent_id"] = agent_id
	out_row["position"] = position
	out_row["velocity"] = velocity
	out_row["intent"] = intent
	out_row["speed_hint"] = maxf(0.0, _to_float(row.get("speed_hint", fallback_max_speed), fallback_max_speed))
	out_row["target_goal"] = _to_vector3(row.get("target_goal", Vector3.ZERO))
	out_row["target_active"] = clampf(_to_float(row.get("target_active", row.get("target_weight", 1.0))), 0.0, 1.0)
	out_row["target_weight"] = clampf(_to_float(row.get("target_weight", 1.0)), 0.0, 1.0)
	out_row["avoidance_goal"] = _to_vector3(row.get("avoidance_goal", Vector3.ZERO))
	out_row["avoidance_active"] = clampf(_to_float(row.get("avoidance_active", 0.0)), 0.0, 1.0)
	out_row["avoidance_weight"] = clampf(_to_float(row.get("avoidance_weight", row.get("obstacle_weight", 0.0))), 0.0, 1.0)
	out_row["flock_center"] = _to_vector3(row.get("flock_center", Vector3.ZERO))
	out_row["flock_velocity"] = _to_vector3(row.get("flock_velocity", Vector3.ZERO))
	return out_row

func _resolve_agent_id(agent: Node) -> String:
	var agent_id_variant := agent.get("rabbit_id")
	if agent_id_variant is String and not (agent_id_variant as String).is_empty():
		return str(agent_id_variant)
	agent_id_variant = agent.get("npc_id")
	if agent_id_variant is String and not (agent_id_variant as String).is_empty():
		return str(agent_id_variant)
	if not String(agent.name).is_empty():
		return agent.name
	return "agent_%d" % agent.get_instance_id()

func _resolve_speed_hint(agent: Node, key: StringName = &"forage_speed") -> float:
	if key != StringName() and agent.has_method("has_method"):
		var value = agent.get(String(key))
		if value is int or value is float:
			return maxf(0.0, float(value))
	var forage_speed = agent.get("forage_speed")
	if forage_speed is int or forage_speed is float:
		return maxf(0.0, float(forage_speed))
	var flee_speed = agent.get("flee_speed")
	if flee_speed is int or flee_speed is float:
		return maxf(0.0, float(flee_speed))
	return fallback_max_speed

func _to_vector3(value: Variant, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if value is Vector3:
		return value
	return fallback

func _to_float(value: Variant, fallback: float = 0.0) -> float:
	if value is int:
		return float(value)
	if value is float:
		return value
	return fallback

func _is_finite_float(value: Variant, minimum: float = 0.0) -> bool:
	if not (value is int or value is float):
		return false
	var float_value := float(value)
	return is_finite(float_value) and float_value >= minimum

func _to_bool(value: Variant) -> bool:
	if value is bool:
		return bool(value)
	return false

func _coerce_string(value: Variant) -> String:
	if value is String:
		return value
	return ""
