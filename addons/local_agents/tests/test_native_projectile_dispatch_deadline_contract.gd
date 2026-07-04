@tool
extends RefCounted

# Native-layer coverage for the projectile "queue-until-dispatch + ack + deadline"
# invariants that were migrated OUT of FpsLauncherController.gd and into the native
# core (LocalAgentsSimulationCore -> LocalAgentsVoxelOrchestration + dispatch bridge).
#
# Invariants asserted here (see test_fps_launcher_contact_rows.gd history):
#   (a) Contact rows enter the native dispatch queue and are NOT consumed until an
#       explicit acknowledge (queue_received_rows accounts them; queue_consumed_rows
#       stays 0 until ack).
#   (b) acknowledge_projectile_contact_rows with a consumed_count records exactly that
#       many consumed/acknowledged rows; consumed_count is the authoritative consumption
#       quantity and mutation_applied is carried through the contract.
#   (c) The deadline contract SURFACE is exposed natively: rows carry deadline_frame into
#       the queue, and the ack result exposes typed deadline-tracking fields
#       (deadline_exceeded_count int + deadline_exceeded_rows Array).
#
# NOT expressible through this surface (documented, not faked):
#   * The controller's former STATEFUL multi-frame purge ("rows that miss the mutation
#     deadline are purged after PROJECTILE_MUTATION_DEADLINE_EXCEEDED with expired_contacts>0")
#     has no equivalent in the native LocalAgentsVoxelOrchestration object: pending_count and
#     deadline_exceeded_rows are stubbed to 0 there because it is a stateless per-tick contract,
#     not a time-based expiry queue. The live earliest_deadline_frame / orchestration_contract
#     (pending_contacts/expired_contacts) computation lives in the full dispatch-tick path and is
#     covered by test_native_orchestration_dispatch_runtime_contract.gd (deadline_frame carried on
#     the dispatch row).
#   * Invariant (d) "the native-tick contract exposes contacts_consumed" is ALREADY covered by
#     test_native_orchestration_dispatch_runtime_contract.gd (_run_contacts_dispatched_uses_native_contract_value_test),
#     so it is not duplicated here.

const ExtensionLoader := preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")

func run_test(_tree: SceneTree) -> bool:
	OS.set_environment("LOCAL_AGENTS_ENABLE_NATIVE_SIM_CORE", "1")
	if not ExtensionLoader.ensure_initialized():
		push_error("LocalAgentsExtensionLoader failed to initialize for native projectile dispatch deadline contract test: %s" % ExtensionLoader.get_error())
		return false
	if not Engine.has_singleton("LocalAgentsSimulationCore"):
		push_error("LocalAgentsSimulationCore singleton unavailable for native projectile dispatch deadline contract test.")
		return false
	var core = Engine.get_singleton("LocalAgentsSimulationCore")
	if core == null:
		push_error("LocalAgentsSimulationCore singleton was null for native projectile dispatch deadline contract test.")
		return false
	if not core.has_method("queue_projectile_contact_rows") or not core.has_method("acknowledge_projectile_contact_rows"):
		push_error("LocalAgentsSimulationCore is missing migrated projectile dispatch queue/ack methods.")
		return false

	var ok := true
	ok = _test_queue_holds_rows_until_ack(core) and ok
	ok = _test_ack_consumption_is_count_authoritative(core) and ok
	ok = _test_deadline_contract_surface_present(core) and ok
	ok = _test_typed_fail_fast_on_invalid_inputs(core) and ok
	ok = _test_configure_and_reset_orchestration(core) and ok
	if ok:
		print("Native projectile dispatch queue/ack/deadline contract tests passed.")
	return ok

func _sample_rows() -> Array:
	return [
		{
			"body_id": 101,
			"contact_point": Vector3(2.0, 1.0, 2.0),
			"contact_impulse": 14.0,
			"contact_velocity": 22.0,
			"relative_speed": 22.0,
			"projectile_kind": "voxel_chunk",
			"projectile_density_tag": "dense",
			"projectile_hardness_tag": "hard",
			"projectile_material_tag": "dense_steel",
			"deadline_frame": 12,
		},
		{
			"body_id": 202,
			"contact_point": Vector3(1.0, 1.0, 1.0),
			"contact_impulse": 11.0,
			"contact_velocity": 18.0,
			"relative_speed": 18.0,
			"projectile_kind": "voxel_chunk",
			"projectile_density_tag": "dense",
			"projectile_hardness_tag": "hard",
			"projectile_material_tag": "dense_steel",
			"deadline_frame": 13,
		},
	]

# Invariant (a): queued rows enter the native dispatch queue and remain unconsumed until ack.
func _test_queue_holds_rows_until_ack(core: Object) -> bool:
	core.call("reset_voxel_orchestration")
	var rows := _sample_rows()
	var queue_result_variant = core.call("queue_projectile_contact_rows", rows, 4)
	var queue_result: Dictionary = queue_result_variant if queue_result_variant is Dictionary else {}

	var ok := true
	ok = _assert(bool(queue_result.get("ok", false)), "Native queue_projectile_contact_rows should accept valid projectile contact rows.") and ok
	ok = _assert(int(queue_result.get("accepted_rows", -1)) == rows.size(), "Native queue should report accepted_rows equal to the queued projectile contact count.") and ok

	var metrics_variant = core.call("get_voxel_orchestration_metrics")
	var metrics: Dictionary = metrics_variant if metrics_variant is Dictionary else {}
	ok = _assert(bool(metrics.get("ok", false)), "Native orchestration metrics should be available after queueing rows.") and ok
	ok = _assert(int(metrics.get("queue_received_rows", -1)) == rows.size(), "Native metrics must account queued projectile contact rows as received for dispatch.") and ok
	ok = _assert(int(metrics.get("queue_received_batches", -1)) == 1, "Native metrics must count the queue batch for dispatch telemetry.") and ok
	# Queue-until-dispatch: rows are received but MUST NOT be consumed before an explicit ack.
	ok = _assert(int(metrics.get("queue_consumed_rows", -1)) == 0, "Queued projectile contact rows must remain unconsumed for native dispatch until explicit ack.") and ok
	ok = _assert(int(metrics.get("queue_acknowledged_rows", -1)) == 0, "Queued projectile contact rows must remain unacknowledged until explicit ack.") and ok

	var state_variant = core.call("get_voxel_orchestration_state")
	var state: Dictionary = state_variant if state_variant is Dictionary else {}
	ok = _assert(bool(state.get("ok", false)), "Native orchestration state should be available after queueing rows.") and ok
	return ok

# Invariant (b): ack records consumption by consumed_count; mutation_applied is carried through.
func _test_ack_consumption_is_count_authoritative(core: Object) -> bool:
	core.call("reset_voxel_orchestration")
	var rows := _sample_rows()
	core.call("queue_projectile_contact_rows", rows, 4)

	var ok := true
	# A non-consuming ack (e.g. dispatch produced no mutation => contacts_consumed=0) must not
	# consume any queued rows. This is the native analogue of the controller's
	# "non-mutating dispatch ack must not clear projectile contact rows".
	var noop_ack_variant = core.call("acknowledge_projectile_contact_rows", 0, false, 5)
	var noop_ack: Dictionary = noop_ack_variant if noop_ack_variant is Dictionary else {}
	ok = _assert(bool(noop_ack.get("ok", false)), "Native ack with consumed_count=0 should succeed.") and ok
	ok = _assert(int(noop_ack.get("consumed_count", -1)) == 0, "Native ack must echo consumed_count=0 for a non-consuming dispatch.") and ok
	ok = _assert(bool(noop_ack.get("mutation_applied", true)) == false, "Native ack must carry mutation_applied=false through the contract.") and ok
	var metrics_after_noop: Dictionary = _metrics(core)
	ok = _assert(int(metrics_after_noop.get("queue_consumed_rows", -1)) == 0, "Non-consuming ack (consumed_count=0) must not increase consumed-row accounting.") and ok

	# A consuming ack with mutation_applied=true records exactly consumed_count rows as consumed.
	var consume_count := rows.size()
	var ack_variant = core.call("acknowledge_projectile_contact_rows", consume_count, true, 6)
	var ack: Dictionary = ack_variant if ack_variant is Dictionary else {}
	ok = _assert(bool(ack.get("ok", false)), "Native ack with a positive consumed_count should succeed.") and ok
	ok = _assert(int(ack.get("consumed_count", -1)) == consume_count, "Native ack must echo the authoritative consumed_count.") and ok
	ok = _assert(bool(ack.get("mutation_applied", false)) == true, "Native ack must carry mutation_applied=true through the contract.") and ok
	var metrics_after: Dictionary = _metrics(core)
	ok = _assert(int(metrics_after.get("queue_consumed_rows", -1)) == consume_count, "Consuming ack must record consumed rows equal to consumed_count.") and ok
	ok = _assert(int(metrics_after.get("queue_acknowledged_rows", -1)) == consume_count, "Consuming ack must record acknowledged rows equal to consumed_count.") and ok
	return ok

# Invariant (c): deadline contract SURFACE is exposed natively on the ack result.
func _test_deadline_contract_surface_present(core: Object) -> bool:
	core.call("reset_voxel_orchestration")
	var rows := _sample_rows()
	core.call("queue_projectile_contact_rows", rows, 4)
	var ack_variant = core.call("acknowledge_projectile_contact_rows", rows.size(), true, 6)
	var ack: Dictionary = ack_variant if ack_variant is Dictionary else {}

	var ok := true
	# The deadline-tracking fields must be present and typed on the migrated ack contract so
	# the dispatch path can report expiries. No violations are expected in this stateless path.
	ok = _assert(ack.has("deadline_exceeded_count"), "Migrated ack contract must expose a deadline_exceeded_count field.") and ok
	ok = _assert(typeof(ack.get("deadline_exceeded_count", null)) == TYPE_INT, "deadline_exceeded_count must be an integer count.") and ok
	ok = _assert(int(ack.get("deadline_exceeded_count", -1)) == 0, "No deadline violations should be reported for a same-window consuming ack.") and ok
	ok = _assert(ack.get("deadline_exceeded_rows", null) is Array, "Migrated ack contract must expose deadline_exceeded_rows as an Array payload.") and ok
	ok = _assert((ack.get("deadline_exceeded_rows", [1]) as Array).is_empty(), "No expired rows should be reported for a same-window consuming ack.") and ok

	var metrics: Dictionary = _metrics(core)
	ok = _assert(metrics.has("deadline_exceeded_rows"), "Native orchestration metrics must expose a deadline_exceeded_rows counter for deadline telemetry.") and ok
	return ok

# Native fail-fast: invalid frame_index / consumed_count must return typed errors, never silently succeed.
func _test_typed_fail_fast_on_invalid_inputs(core: Object) -> bool:
	core.call("reset_voxel_orchestration")
	var ok := true

	var bad_queue_variant = core.call("queue_projectile_contact_rows", _sample_rows(), -1)
	var bad_queue: Dictionary = bad_queue_variant if bad_queue_variant is Dictionary else {}
	ok = _assert(not bool(bad_queue.get("ok", true)), "Queueing with a negative frame_index must fail closed.") and ok
	ok = _assert(String(bad_queue.get("error_code", "")) == "INVALID_FRAME_INDEX", "Negative frame_index queue must return the typed INVALID_FRAME_INDEX error_code.") and ok

	var bad_ack_frame_variant = core.call("acknowledge_projectile_contact_rows", 1, true, -1)
	var bad_ack_frame: Dictionary = bad_ack_frame_variant if bad_ack_frame_variant is Dictionary else {}
	ok = _assert(not bool(bad_ack_frame.get("ok", true)), "Acknowledging with a negative frame_index must fail closed.") and ok
	ok = _assert(String(bad_ack_frame.get("error_code", "")) == "INVALID_FRAME_INDEX", "Negative frame_index ack must return the typed INVALID_FRAME_INDEX error_code.") and ok

	var bad_ack_count_variant = core.call("acknowledge_projectile_contact_rows", -3, true, 5)
	var bad_ack_count: Dictionary = bad_ack_count_variant if bad_ack_count_variant is Dictionary else {}
	ok = _assert(not bool(bad_ack_count.get("ok", true)), "Acknowledging with a negative consumed_count must fail closed.") and ok
	ok = _assert(String(bad_ack_count.get("error_code", "")) == "INVALID_CONSUMED_COUNT", "Negative consumed_count ack must return the typed INVALID_CONSUMED_COUNT error_code.") and ok
	return ok

# configure + reset behavior for the migrated orchestration state/metrics.
func _test_configure_and_reset_orchestration(core: Object) -> bool:
	core.call("reset_voxel_orchestration")
	var ok := true

	var configure_variant = core.call("configure_voxel_orchestration", {
		"cadence_frames": 3,
		"max_rows_per_tick": 32,
		"stage_name": "voxel_transform_step",
	})
	var configure_result: Dictionary = configure_variant if configure_variant is Dictionary else {}
	ok = _assert(bool(configure_result.get("ok", false)), "configure_voxel_orchestration should accept a valid config.") and ok
	var state: Dictionary = _state(core)
	var config_variant = state.get("config", {})
	var config: Dictionary = config_variant if config_variant is Dictionary else {}
	ok = _assert(int(config.get("cadence_frames", -1)) == 3, "configure_voxel_orchestration should apply cadence_frames into orchestration state.") and ok
	ok = _assert(int(config.get("max_rows_per_tick", -1)) == 32, "configure_voxel_orchestration should apply max_rows_per_tick into orchestration state.") and ok
	ok = _assert(String(config.get("stage_name", "")) == "voxel_transform_step", "configure_voxel_orchestration should apply the canonical stage_name into orchestration state.") and ok

	# Populate counters, then confirm reset clears them.
	core.call("queue_projectile_contact_rows", _sample_rows(), 4)
	core.call("acknowledge_projectile_contact_rows", 1, true, 5)
	var populated: Dictionary = _metrics(core)
	ok = _assert(int(populated.get("queue_received_rows", 0)) > 0, "Sanity: queued rows should register before reset.") and ok

	core.call("reset_voxel_orchestration")
	var reset_metrics: Dictionary = _metrics(core)
	ok = _assert(int(reset_metrics.get("queue_received_rows", -1)) == 0, "reset_voxel_orchestration must clear received-row accounting.") and ok
	ok = _assert(int(reset_metrics.get("queue_consumed_rows", -1)) == 0, "reset_voxel_orchestration must clear consumed-row accounting.") and ok
	ok = _assert(int(reset_metrics.get("queue_received_batches", -1)) == 0, "reset_voxel_orchestration must clear batch accounting.") and ok
	return ok

func _metrics(core: Object) -> Dictionary:
	var metrics_variant = core.call("get_voxel_orchestration_metrics")
	return metrics_variant if metrics_variant is Dictionary else {}

func _state(core: Object) -> Dictionary:
	var state_variant = core.call("get_voxel_orchestration_state")
	return state_variant if state_variant is Dictionary else {}

func _assert(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
