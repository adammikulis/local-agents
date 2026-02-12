extends Node3D

@onready var ecology_controller: Node3D = $EcologyController
@onready var debug_overlay: Node3D = $DebugOverlayRoot

func _ready() -> void:
	if ecology_controller.has_method("set_debug_overlay"):
		ecology_controller.call("set_debug_overlay", debug_overlay)
