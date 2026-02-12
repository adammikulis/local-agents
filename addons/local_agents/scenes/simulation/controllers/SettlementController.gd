extends Node3D

@onready var settlement_root: Node3D = $SettlementRoot

func clear_generated() -> void:
	for child in settlement_root.get_children():
		child.queue_free()
