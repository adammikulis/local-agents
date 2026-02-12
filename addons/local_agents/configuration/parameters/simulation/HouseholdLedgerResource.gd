extends Resource
class_name LocalAgentsHouseholdLedgerResource

@export var household_id: String = ""
@export var food: float = 0.0
@export var water: float = 0.0
@export var wood: float = 0.0
@export var stone: float = 0.0
@export var tools: float = 0.0
@export var currency: float = 0.0
@export var debt: float = 0.0
@export var housing_quality: float = 0.5
@export var waste: float = 0.0

func to_dict() -> Dictionary:
    return {
        "household_id": household_id,
        "food": food,
        "water": water,
        "wood": wood,
        "stone": stone,
        "tools": tools,
        "currency": currency,
        "debt": debt,
        "housing_quality": housing_quality,
        "waste": waste,
    }
