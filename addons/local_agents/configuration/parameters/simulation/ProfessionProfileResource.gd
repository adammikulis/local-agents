extends Resource
class_name LocalAgentsProfessionProfileResource

@export var profession_id: String = "general"
@export var food_rate: float = 0.08
@export var water_rate: float = 0.0
@export var wood_rate: float = 0.05
@export var stone_rate: float = 0.0
@export var tools_rate: float = 0.0
@export var currency_rate: float = 0.04
@export var wage_rate: float = 0.03

func to_dict() -> Dictionary:
    return {
        "profession_id": profession_id,
        "food_rate": food_rate,
        "water_rate": water_rate,
        "wood_rate": wood_rate,
        "stone_rate": stone_rate,
        "tools_rate": tools_rate,
        "currency_rate": currency_rate,
        "wage_rate": wage_rate,
    }
