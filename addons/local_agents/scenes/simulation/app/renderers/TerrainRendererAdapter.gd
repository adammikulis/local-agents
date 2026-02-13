extends RefCounted
class_name LocalAgentsTerrainRendererAdapter

func apply_generation(environment_controller: Node3D, world_snapshot: Dictionary, hydrology_snapshot: Dictionary, chunk_size: int) -> void:
	if environment_controller == null:
		return
	if environment_controller.has_method("set_terrain_chunk_size"):
		environment_controller.call("set_terrain_chunk_size", chunk_size)
	if environment_controller.has_method("apply_generation_data"):
		environment_controller.call("apply_generation_data", world_snapshot, hydrology_snapshot)

func apply_delta(environment_controller: Node3D, world_snapshot: Dictionary, hydrology_snapshot: Dictionary, changed_tiles: Array) -> void:
	if environment_controller == null:
		return
	if environment_controller.has_method("apply_generation_delta"):
		environment_controller.call("apply_generation_delta", world_snapshot, hydrology_snapshot, changed_tiles)
	elif environment_controller.has_method("apply_generation_data"):
		environment_controller.call("apply_generation_data", world_snapshot, hydrology_snapshot)
