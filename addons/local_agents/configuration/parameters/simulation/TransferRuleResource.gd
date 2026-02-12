extends Resource
class_name LocalAgentsTransferRuleResource

@export var ration_food_per_member: float = 0.5
@export var ration_water_per_member: float = 0.5
@export var ration_currency_per_member: float = 0.03

@export var household_food_consumption_per_member: float = 0.45
@export var household_water_consumption_per_member: float = 0.4
@export var household_waste_per_member: float = 0.09

@export var individual_food_consumption: float = 0.08
@export var individual_water_consumption: float = 0.07
@export var individual_energy_consumption: float = 0.03
@export var individual_waste_generation: float = 0.04

@export var tax_rate: float = 0.03
@export var trade_surplus_sell_fraction: float = 0.35

func to_dict() -> Dictionary:
    return {
        "ration_food_per_member": ration_food_per_member,
        "ration_water_per_member": ration_water_per_member,
        "ration_currency_per_member": ration_currency_per_member,
        "household_food_consumption_per_member": household_food_consumption_per_member,
        "household_water_consumption_per_member": household_water_consumption_per_member,
        "household_waste_per_member": household_waste_per_member,
        "individual_food_consumption": individual_food_consumption,
        "individual_water_consumption": individual_water_consumption,
        "individual_energy_consumption": individual_energy_consumption,
        "individual_waste_generation": individual_waste_generation,
        "tax_rate": tax_rate,
        "trade_surplus_sell_fraction": trade_surplus_sell_fraction,
    }
