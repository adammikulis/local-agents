extends RefCounted
class_name LocalAgentsCommunityLedgerSystem

const LedgerScript = preload("res://addons/local_agents/configuration/parameters/simulation/CommunityLedgerResource.gd")

const RESOURCE_KEYS := ["food", "water", "wood", "stone", "tools", "currency", "labor_pool"]

func initial_community_ledger():
    return LedgerScript.new()

func produce(ledger, villager_count: int, tick: int):
    var out = _copy(ledger)
    var count := max(villager_count, 0)
    var day_factor := 1.0 if (tick % 24) < 18 else 0.65
    out.food += 0.18 * count * day_factor
    out.water += 0.14 * count
    out.wood += 0.05 * count
    out.stone += 0.03 * count
    out.currency += 0.02 * count
    return clamp_to_capacity(out)

func consume_upkeep(ledger, building_load: float = 1.0):
    var out = _copy(ledger)
    out.tools = maxf(0.0, out.tools - (0.03 * building_load))
    out.wood = maxf(0.0, out.wood - (0.04 * building_load))
    out.stone = maxf(0.0, out.stone - (0.02 * building_load))
    return out

func withdraw(ledger, requested: Dictionary) -> Dictionary:
    var out = _copy(ledger)
    var granted := {}
    for key in requested.keys():
        var amount := maxf(0.0, float(requested[key]))
        var available := maxf(0.0, _get_resource(out, String(key)))
        var take := minf(amount, available)
        _set_resource(out, String(key), available - take)
        granted[String(key)] = take
    return {"ledger": out, "granted": granted}

func deposit(ledger, incoming: Dictionary):
    var out = _copy(ledger)
    for key in incoming.keys():
        var resource := String(key)
        _set_resource(out, resource, _get_resource(out, resource) + maxf(0.0, float(incoming[key])))
    return clamp_to_capacity(out)

func clamp_to_capacity(ledger):
    var out = _copy(ledger)
    var capacity := maxf(1.0, out.storage_capacity)
    var stored := 0.0
    for key in RESOURCE_KEYS:
        stored += maxf(0.0, _get_resource(out, key))
    if stored <= capacity:
        return out

    var ratio := capacity / stored
    var spoiled := 0.0
    for key in RESOURCE_KEYS:
        var current := maxf(0.0, _get_resource(out, key))
        var kept := current * ratio
        spoiled += current - kept
        _set_resource(out, key, kept)
    out.spoiled += spoiled
    return out

func _copy(ledger):
    return ledger.duplicate(true)

func _get_resource(ledger, resource: String) -> float:
    match resource:
        "food": return ledger.food
        "water": return ledger.water
        "wood": return ledger.wood
        "stone": return ledger.stone
        "tools": return ledger.tools
        "currency": return ledger.currency
        "labor_pool": return ledger.labor_pool
        "waste": return ledger.waste
        _: return 0.0

func _set_resource(ledger, resource: String, value: float) -> void:
    match resource:
        "food": ledger.food = value
        "water": ledger.water = value
        "wood": ledger.wood = value
        "stone": ledger.stone = value
        "tools": ledger.tools = value
        "currency": ledger.currency = value
        "labor_pool": ledger.labor_pool = value
        "waste": ledger.waste = value
