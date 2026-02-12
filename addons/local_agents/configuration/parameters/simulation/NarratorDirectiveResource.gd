extends Resource
class_name LocalAgentsNarratorDirectiveResource

@export var text: String = ""
@export var updated_at_tick: int = -1

func set_text(next_text: String, tick: int = -1) -> void:
    text = next_text
    updated_at_tick = tick

func to_dict() -> Dictionary:
    return {
        "text": text,
        "updated_at_tick": updated_at_tick,
    }
