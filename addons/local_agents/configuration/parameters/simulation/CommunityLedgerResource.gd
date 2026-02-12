extends Resource
class_name LocalAgentsCommunityLedgerResource

@export var food: float = 120.0
@export var water: float = 120.0
@export var wood: float = 80.0
@export var stone: float = 50.0
@export var tools: float = 20.0
@export var currency: float = 200.0
@export var labor_pool: float = 0.0
@export var storage_capacity: float = 500.0
@export var spoiled: float = 0.0
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
        "storage_capacity": storage_capacity,
        "spoiled": spoiled,
        "waste": waste,
    }
