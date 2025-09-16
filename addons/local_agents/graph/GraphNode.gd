extends Resource
class_name LocalAgentsGraphNode

@export var id: int = 0
@export var name: String = ""
@export var data: Dictionary = {}

func _init(p_id: int = 0, p_name: String = "", p_data: Dictionary = {}):
    id = p_id
    name = p_name
    data = p_data.duplicate(true)
