extends Node3D

@onready var settlement_root: Node3D = $SettlementRoot
const HutPrimitiveScene = preload("res://addons/local_agents/scenes/simulation/settlement/HutPrimitive.tscn")
const StoragePrimitiveScene = preload("res://addons/local_agents/scenes/simulation/settlement/StoragePrimitive.tscn")
const HearthPrimitiveScene = preload("res://addons/local_agents/scenes/simulation/settlement/HearthPrimitive.tscn")
const SacredSitePrimitiveScene = preload("res://addons/local_agents/scenes/simulation/settlement/SacredSitePrimitive.tscn")
var _spawn_snapshot: Dictionary = {}

func clear_generated() -> void:
	for child in settlement_root.get_children():
		child.queue_free()

func spawn_initial_settlement(spawn_artifact: Dictionary) -> void:
	_spawn_snapshot = spawn_artifact.duplicate(true)
	clear_generated()
	var chosen: Dictionary = _spawn_snapshot.get("chosen", {})
	if chosen.is_empty():
		return

	var x = float(chosen.get("x", 0))
	var y = float(chosen.get("y", 0))
	var center = Vector3(x, 0.0, y)
	_spawn_structure(HearthPrimitiveScene, "Hearth_0", center)
	_spawn_structure(StoragePrimitiveScene, "Storage_0", center + Vector3(1.5, 0.0, 0.5))
	_spawn_structure(SacredSitePrimitiveScene, "SacredSite_0", center + Vector3(-1.5, 0.0, -0.5))

	for idx in range(3):
		var angle = (TAU / 3.0) * float(idx)
		var offset = Vector3(cos(angle), 0.0, sin(angle)) * 2.8
		_spawn_structure(HutPrimitiveScene, "Hut_%d" % idx, center + offset)

func get_spawn_snapshot() -> Dictionary:
	return _spawn_snapshot.duplicate(true)

func _spawn_structure(scene: PackedScene, structure_id: String, position_3d: Vector3) -> void:
	var instance = scene.instantiate()
	instance.name = structure_id
	instance.position = position_3d
	instance.set_meta("structure_id", structure_id)
	settlement_root.add_child(instance)
