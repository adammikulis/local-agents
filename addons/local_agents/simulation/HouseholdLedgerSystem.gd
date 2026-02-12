extends RefCounted
class_name LocalAgentsHouseholdLedgerSystem

const LedgerScript = preload("res://addons/local_agents/configuration/parameters/simulation/HouseholdLedgerResource.gd")

func initial_household_ledger(household_id: String):
    var ledger = LedgerScript.new()
    ledger.household_id = household_id
    ledger.food = 6.0
    ledger.water = 6.0
    ledger.wood = 1.5
    ledger.stone = 0.8
    ledger.tools = 0.4
    ledger.currency = 2.0
    return ledger

func ration_request_for_members(member_count: int, transfer_rules) -> Dictionary:
    var n := max(member_count, 1)
    return {
        "food": transfer_rules.ration_food_per_member * n,
        "water": transfer_rules.ration_water_per_member * n,
        "currency": transfer_rules.ration_currency_per_member * n,
    }

func apply_ration(ledger, ration: Dictionary):
    var out = ledger.duplicate(true)
    out.food += maxf(0.0, float(ration.get("food", 0.0)))
    out.water += maxf(0.0, float(ration.get("water", 0.0)))
    out.currency += maxf(0.0, float(ration.get("currency", 0.0)))
    return out

func consume_for_members(ledger, member_count: int, transfer_rules):
    var out = ledger.duplicate(true)
    var n := max(member_count, 1)
    out.food = maxf(0.0, out.food - (transfer_rules.household_food_consumption_per_member * n))
    out.water = maxf(0.0, out.water - (transfer_rules.household_water_consumption_per_member * n))
    out.waste = maxf(0.0, out.waste + (transfer_rules.household_waste_per_member * n))
    return out

func collect_tax(ledger, transfer_rules) -> Dictionary:
    var out = ledger.duplicate(true)
    var curr := maxf(0.0, out.currency)
    var tax := curr * clampf(transfer_rules.tax_rate, 0.0, 0.5)
    out.currency = curr - tax
    return {
        "ledger": out,
        "tax": tax,
    }

func enforce_non_negative(ledger):
    var out = ledger.duplicate(true)
    out.food = maxf(0.0, out.food)
    out.water = maxf(0.0, out.water)
    out.wood = maxf(0.0, out.wood)
    out.stone = maxf(0.0, out.stone)
    out.tools = maxf(0.0, out.tools)
    out.currency = maxf(0.0, out.currency)
    out.debt = maxf(0.0, out.debt)
    out.waste = maxf(0.0, out.waste)
    out.housing_quality = clampf(out.housing_quality, 0.0, 1.0)
    return out
