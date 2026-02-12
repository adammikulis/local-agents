extends Resource
class_name LocalAgentsResourceBundleResource

@export var food: float = 0.0
@export var water: float = 0.0
@export var wood: float = 0.0
@export var stone: float = 0.0
@export var tools: float = 0.0
@export var currency: float = 0.0
@export var labor_pool: float = 0.0
@export var waste: float = 0.0

func to_dict() -> Dictionary:
    return {
        "food": food,
        "water": water,
        "wood": wood,
        "stone": stone,
        "tools": tools,
        "currency": currency,
        "labor_pool": labor_pool,
        "waste": waste,
    }

func from_dict(values: Dictionary) -> void:
    food = float(values.get("food", 0.0))
    water = float(values.get("water", 0.0))
    wood = float(values.get("wood", 0.0))
    stone = float(values.get("stone", 0.0))
    tools = float(values.get("tools", 0.0))
    currency = float(values.get("currency", 0.0))
    labor_pool = float(values.get("labor_pool", 0.0))
    waste = float(values.get("waste", 0.0))
