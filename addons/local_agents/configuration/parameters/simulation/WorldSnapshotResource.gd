extends Resource
class_name LocalAgentsWorldSnapshotResource

@export var tick: int = 0
@export var data: Dictionary = {}

func set_from_dictionary(source: Dictionary, at_tick: int = -1) -> void:
	if at_tick >= 0:
		tick = at_tick
	data = source.duplicate(true)

func to_dictionary() -> Dictionary:
	return data.duplicate(true)
