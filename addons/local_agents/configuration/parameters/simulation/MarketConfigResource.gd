extends Resource
class_name LocalAgentsMarketConfigResource

@export var food_base_price: float = 1.0
@export var water_base_price: float = 0.8
@export var wood_base_price: float = 1.4
@export var stone_base_price: float = 1.5
@export var tools_base_price: float = 2.2

@export var scarcity_floor_multiplier: float = 0.85
@export var scarcity_ceiling_multiplier: float = 2.35
@export var scarcity_stock_fraction: float = 0.2

func base_prices() -> Dictionary:
    return {
        "food": food_base_price,
        "water": water_base_price,
        "wood": wood_base_price,
        "stone": stone_base_price,
        "tools": tools_base_price,
    }

func to_dict() -> Dictionary:
    return {
        "base_prices": base_prices(),
        "scarcity_floor_multiplier": scarcity_floor_multiplier,
        "scarcity_ceiling_multiplier": scarcity_ceiling_multiplier,
        "scarcity_stock_fraction": scarcity_stock_fraction,
    }
