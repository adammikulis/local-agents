extends Resource
class_name LocalAgentsCarryProfileResource

@export var strength: float = 0.5
@export var tool_efficiency: float = 0.0
@export var base_capacity: float = 0.65
@export var strength_multiplier: float = 0.85
@export var max_tool_bonus: float = 1.2
@export var tool_bonus_factor: float = 0.15
@export var min_capacity: float = 0.2

func capacity() -> float:
    var bonus := minf(max_tool_bonus, maxf(0.0, tool_efficiency) * tool_bonus_factor)
    return maxf(min_capacity, base_capacity + (clampf(strength, 0.0, 1.5) * strength_multiplier) + bonus)

func to_dict() -> Dictionary:
    return {
        "strength": strength,
        "tool_efficiency": tool_efficiency,
        "base_capacity": base_capacity,
        "strength_multiplier": strength_multiplier,
        "max_tool_bonus": max_tool_bonus,
        "tool_bonus_factor": tool_bonus_factor,
        "min_capacity": min_capacity,
        "capacity": capacity(),
    }
