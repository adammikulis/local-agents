extends Resource
class_name LocalAgentsGraphRule

@export var condition: Callable = Callable()
@export var memory_threshold: float = 0.0

func _init(p_condition: Callable = Callable(), p_threshold: float = 0.0):
    condition = p_condition
    memory_threshold = p_threshold

func evaluate(variable: String, delta: float) -> Array:
    if not condition.is_valid():
        return ["", false]
    var result = condition.call(variable, delta)
    if result is Array and result.size() >= 2:
        return [str(result[0]), bool(result[1])]
    return ["", false]
