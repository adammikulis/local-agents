extends Resource
class_name LocalAgentsVillagerInventoryResource

@export var food: float = 0.0
@export var water: float = 0.0
@export var wood: float = 0.0
@export var stone: float = 0.0
@export var tools: float = 0.0
@export var currency: float = 0.0
@export var waste: float = 0.0

@export var carried_food: float = 0.0
@export var carried_water: float = 0.0
@export var carried_wood: float = 0.0
@export var carried_stone: float = 0.0
@export var carried_tools: float = 0.0
@export var carried_currency: float = 0.0
@export var carried_weight: float = 0.0

func to_dict() -> Dictionary:
    return {
        "food": food,
        "water": water,
        "wood": wood,
        "stone": stone,
        "tools": tools,
        "currency": currency,
        "waste": waste,
        "carried_food": carried_food,
        "carried_water": carried_water,
        "carried_wood": carried_wood,
        "carried_stone": carried_stone,
        "carried_tools": carried_tools,
        "carried_currency": carried_currency,
        "carried_weight": carried_weight,
    }
