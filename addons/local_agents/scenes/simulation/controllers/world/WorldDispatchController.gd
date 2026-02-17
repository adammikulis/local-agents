extends RefCounted
class_name LocalAgentsWorldDispatchController

var _native_stage_name: StringName = &"voxel_transform_step"
var _mutation_glow_handler: Callable = Callable()
var _native_bridge: Object = null

func configure(native_stage_name: StringName) -> void:
	_native_stage_name = native_stage_name if native_stage_name != StringName() else &"voxel_transform_step"

func set_mutation_glow_handler(handler: Callable) -> void:
	_mutation_glow_handler = handler if handler.is_valid() else Callable()

func process_native_voxel_rate(delta: float, context: Dictionary) -> Dictionary:
	var bridge := _resolve_native_bridge()
	if bridge == null or not bridge.has_method("process_native_voxel_rate"):
		return {
			"ok": false,
			"dispatched": false,
			"mutation_applied": false,
			"contacts_consumed": 0,
			"error": "native_voxel_dispatch_bridge_unavailable",
		}
	var bridge_context := context.duplicate(false)
	bridge_context["native_stage_name"] = String(_native_stage_name)
	bridge_context["mutation_glow_handler"] = _mutation_glow_handler
	var result_variant = bridge.call("process_native_voxel_rate", delta, bridge_context)
	if result_variant is Dictionary:
		return (result_variant as Dictionary).duplicate(true)
	return {
		"ok": false,
		"dispatched": false,
		"mutation_applied": false,
		"contacts_consumed": 0,
		"error": "invalid_native_voxel_dispatch_bridge_result",
	}

func _resolve_native_bridge() -> Object:
	if is_instance_valid(_native_bridge):
		return _native_bridge
	var bridge := ClassDB.instantiate("LocalAgentsVoxelDispatchBridge")
	if bridge == null:
		return null
	_native_bridge = bridge
	return _native_bridge
