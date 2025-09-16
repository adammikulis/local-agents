extends Resource
class_name LocalAgentsGraphEdge

@export var id: int = 0
@export var source_id: int = 0
@export var target_id: int = 0
@export var name: String = ""
@export var weight: float = 1.0
@export var data: Dictionary = {}

func _init(p_id: int = 0, p_source: int = 0, p_target: int = 0, p_name: String = "", p_weight: float = 1.0, p_data: Dictionary = {}):
    id = p_id
    source_id = p_source
    target_id = p_target
    name = p_name
    weight = p_weight
    data = p_data.duplicate(true)

func update_weight(amount: float) -> void:
    weight += amount
