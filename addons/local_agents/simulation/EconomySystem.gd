extends RefCounted
class_name LocalAgentsEconomySystem

const MarketConfigScript = preload("res://addons/local_agents/configuration/parameters/simulation/MarketConfigResource.gd")
const TransferRuleScript = preload("res://addons/local_agents/configuration/parameters/simulation/TransferRuleResource.gd")
const ProfessionScript = preload("res://addons/local_agents/configuration/parameters/simulation/ProfessionProfileResource.gd")

const RESOURCE_ORDER := ["food", "water", "wood", "stone", "tools", "currency"]
const RESOURCE_WEIGHT := {
    "food": 1.0,
    "water": 1.0,
    "wood": 1.4,
    "stone": 1.7,
    "tools": 1.2,
    "currency": 0.2,
}

var market_config
var transfer_rules
var _profession_profiles: Dictionary = {}

func _init() -> void:
    market_config = MarketConfigScript.new()
    transfer_rules = TransferRuleScript.new()
    _ensure_default_professions()

func set_market_config(config) -> void:
    if config != null:
        market_config = config

func set_transfer_rules(config) -> void:
    if config != null:
        transfer_rules = config

func set_profession_profile(profile) -> void:
    if profile == null:
        return
    var key := String(profile.profession_id)
    if key.strip_edges() == "":
        return
    _profession_profiles[key] = profile

func compute_market_prices(community_ledger) -> Dictionary:
    var prices := {}
    var storage_capacity := maxf(1.0, float(community_ledger.storage_capacity))
    var bases: Dictionary = market_config.base_prices()
    for key in bases.keys():
        var resource := String(key)
        var stock := maxf(0.0, _community_value(community_ledger, resource))
        var scarcity := 1.0 - clampf(stock / (storage_capacity * maxf(0.01, market_config.scarcity_stock_fraction)), 0.0, 1.0)
        var floor := maxf(0.01, market_config.scarcity_floor_multiplier)
        var ceiling := maxf(floor, market_config.scarcity_ceiling_multiplier)
        var multiplier := lerpf(floor, ceiling, scarcity)
        prices[resource] = maxf(0.01, float(bases[resource]) * multiplier)
    return prices

func villager_production(villager_state: Dictionary, economy_state, tick: int) -> Dictionary:
    var role := String(villager_state.get("profession", "general"))
    var profile = _profession_profiles.get(role, _profession_profiles.get("general", null))
    if profile == null:
        _ensure_default_professions()
        profile = _profession_profiles.get("general", null)

    var fatigue := 1.0 - clampf(1.0 - float(economy_state.energy), 0.0, 0.8)
    var work_factor := 1.0 if (tick % 24) >= 7 and (tick % 24) <= 18 else 0.35
    return {
        "food": float(profile.food_rate) * fatigue * work_factor,
        "water": float(profile.water_rate) * fatigue * work_factor,
        "wood": float(profile.wood_rate) * fatigue * work_factor,
        "stone": float(profile.stone_rate) * fatigue * work_factor,
        "tools": float(profile.tools_rate) * fatigue * work_factor,
        "currency": float(profile.currency_rate) * fatigue * work_factor,
        "wage_due": float(profile.wage_rate) * work_factor,
    }

func transport_capacity_for_member(carry_profile) -> float:
    return maxf(0.2, float(carry_profile.capacity()))

func total_transport_capacity(member_ids: Array, carry_profiles: Dictionary) -> float:
    var total := 0.0
    for npc_id_variant in member_ids:
        var npc_id := String(npc_id_variant)
        var profile = carry_profiles.get(npc_id, null)
        if profile == null:
            continue
        total += transport_capacity_for_member(profile)
    return total

func payload_weight(payload: Dictionary) -> float:
    var total := 0.0
    for key in payload.keys():
        var resource := String(key)
        var amount := maxf(0.0, float(payload[resource]))
        var weight := float(RESOURCE_WEIGHT.get(resource, 1.0))
        total += amount * weight
    return total

func allocate_carrier_assignments(payload: Dictionary, member_ids: Array, carry_profiles: Dictionary) -> Dictionary:
    var assignments := {}
    var moved_payload := {}
    var remaining := payload.duplicate(true)
    var sorted_ids := member_ids.duplicate()
    sorted_ids.sort()
    for npc_id_variant in sorted_ids:
        var npc_id := String(npc_id_variant)
        assignments[npc_id] = {}
        var profile = carry_profiles.get(npc_id, null)
        if profile == null:
            continue
        var cap := transport_capacity_for_member(profile)
        var used := 0.0
        for resource in RESOURCE_ORDER:
            var amount := maxf(0.0, float(remaining.get(resource, 0.0)))
            if amount <= 0.0:
                continue
            var weight := float(RESOURCE_WEIGHT.get(resource, 1.0))
            var free := maxf(0.0, cap - used)
            if free <= 0.0:
                break
            var max_amount := free / maxf(0.0001, weight)
            var moved := minf(amount, max_amount)
            if moved <= 0.0:
                continue
            assignments[npc_id][resource] = moved
            moved_payload[resource] = float(moved_payload.get(resource, 0.0)) + moved
            remaining[resource] = amount - moved
            used += moved * weight
    return {
        "assignments": assignments,
        "moved_payload": moved_payload,
        "remaining_payload": remaining,
    }

func assignment_weight(assignment: Dictionary) -> float:
    return payload_weight(assignment)

func household_trade_step(household_ledger, community_ledger, prices: Dictionary, transport_capacity_weight: float) -> Dictionary:
    var home = household_ledger.duplicate(true)
    var town = community_ledger.duplicate(true)
    var spent := 0.0
    var earned := 0.0
    var trades: Array = []
    var transport_payload := {}
    var weight_used := 0.0
    var capacity := maxf(0.0, transport_capacity_weight)

    var targets := {"food": 2.5, "water": 2.5, "wood": 0.8}
    for key in targets.keys():
        var resource := String(key)
        var target := float(targets[resource])
        var have := _household_value(home, resource)
        if have >= target:
            continue
        var need := target - have
        var price := maxf(0.01, float(prices.get(resource, 1.0)))
        var affordability := _household_value(home, "currency") / price
        var market_available := _community_value(town, resource)
        var max_by_weight := INF
        var weight := float(RESOURCE_WEIGHT.get(resource, 1.0))
        if capacity > 0.0:
            var free := maxf(0.0, capacity - weight_used)
            max_by_weight = free / maxf(0.0001, weight)
        var buy_amount := minf(need, minf(affordability, minf(market_available, max_by_weight)))
        if buy_amount <= 0.0:
            continue
        _set_household_value(home, resource, have + buy_amount)
        var cost := buy_amount * price
        home.currency = maxf(0.0, home.currency - cost)
        _set_community_value(town, resource, maxf(0.0, market_available - buy_amount))
        town.currency += cost
        spent += cost
        weight_used += buy_amount * weight
        transport_payload[resource] = float(transport_payload.get(resource, 0.0)) + buy_amount
        trades.append({"side": "buy", "resource": resource, "amount": buy_amount, "price": price})

    var reserves := {"food": 4.0, "water": 4.0, "wood": 2.5, "stone": 1.5}
    for key in reserves.keys():
        var resource := String(key)
        var reserve := float(reserves[resource])
        var have := _household_value(home, resource)
        if have <= reserve:
            continue
        var sell_amount: float = (have - reserve) * transfer_rules.trade_surplus_sell_fraction
        var price := maxf(0.01, float(prices.get(resource, 1.0)))
        var weight := float(RESOURCE_WEIGHT.get(resource, 1.0))
        if capacity > 0.0:
            var free := maxf(0.0, capacity - weight_used)
            var max_by_weight := free / maxf(0.0001, weight)
            sell_amount = minf(sell_amount, max_by_weight)
        if sell_amount <= 0.0:
            continue
        _set_household_value(home, resource, have - sell_amount)
        var revenue: float = sell_amount * price
        home.currency += revenue
        _set_community_value(town, resource, _community_value(town, resource) + sell_amount)
        town.currency = maxf(0.0, town.currency - revenue)
        earned += revenue
        weight_used += sell_amount * weight
        transport_payload[resource] = float(transport_payload.get(resource, 0.0)) + sell_amount
        trades.append({"side": "sell", "resource": resource, "amount": sell_amount, "price": price})

    return {
        "household": home,
        "community": town,
        "spent": spent,
        "earned": earned,
        "trades": trades,
        "transport_payload": transport_payload,
        "transport_weight_used": weight_used,
        "transport_capacity_weight": capacity,
    }

func process_waste(community_ledger, household_ledgers: Dictionary, individual_ledgers: Dictionary) -> Dictionary:
    var community = community_ledger.duplicate(true)
    var households = household_ledgers.duplicate(true)
    var individuals = individual_ledgers.duplicate(true)

    var household_waste := 0.0
    for hid in households.keys():
        var ledger = households[hid]
        household_waste += float(ledger.waste)
        ledger.waste = maxf(0.0, ledger.waste * 0.6)
        households[hid] = ledger

    var individual_waste := 0.0
    for npc_id in individuals.keys():
        var state = individuals[npc_id]
        var inv = state.inventory
        individual_waste += float(inv.waste)
        inv.waste = maxf(0.0, inv.waste * 0.5)
        individuals[npc_id] = state

    var incoming := household_waste + individual_waste
    community.waste += incoming

    var process_capacity := 0.35 + (0.01 * maxf(0.0, community.tools))
    var current_waste: float = float(community.waste)
    var processed := minf(current_waste, process_capacity)
    community.waste = maxf(0.0, current_waste - processed)
    var recycled_wood := processed * 0.12
    var recycled_currency := processed * 0.08
    community.wood += recycled_wood
    community.currency += recycled_currency

    return {
        "community": community,
        "households": households,
        "individuals": individuals,
        "incoming_waste": incoming,
        "processed_waste": processed,
        "recycled_wood": recycled_wood,
        "recycled_currency": recycled_currency,
    }

func _ensure_default_professions() -> void:
    if not _profession_profiles.is_empty():
        return
    _profession_profiles["general"] = _make_profile("general", 0.08, 0.0, 0.05, 0.0, 0.0, 0.04, 0.03)
    _profession_profiles["farmer"] = _make_profile("farmer", 0.25, 0.05, 0.0, 0.0, 0.0, 0.0, 0.04)
    _profession_profiles["woodcutter"] = _make_profile("woodcutter", 0.0, 0.0, 0.22, 0.0, 0.03, 0.0, 0.04)
    _profession_profiles["mason"] = _make_profile("mason", 0.0, 0.0, 0.0, 0.2, 0.02, 0.0, 0.05)
    _profession_profiles["merchant"] = _make_profile("merchant", 0.0, 0.0, 0.0, 0.0, 0.0, 0.12, 0.05)

func _make_profile(id: String, food: float, water: float, wood: float, stone: float, tools: float, currency: float, wage: float):
    var p = ProfessionScript.new()
    p.profession_id = id
    p.food_rate = food
    p.water_rate = water
    p.wood_rate = wood
    p.stone_rate = stone
    p.tools_rate = tools
    p.currency_rate = currency
    p.wage_rate = wage
    return p

func _community_value(community, resource: String) -> float:
    match resource:
        "food": return community.food
        "water": return community.water
        "wood": return community.wood
        "stone": return community.stone
        "tools": return community.tools
        "currency": return community.currency
        "labor_pool": return community.labor_pool
        "waste": return community.waste
        _: return 0.0

func _set_community_value(community, resource: String, value: float) -> void:
    match resource:
        "food": community.food = value
        "water": community.water = value
        "wood": community.wood = value
        "stone": community.stone = value
        "tools": community.tools = value
        "currency": community.currency = value
        "labor_pool": community.labor_pool = value
        "waste": community.waste = value

func _household_value(household, resource: String) -> float:
    match resource:
        "food": return household.food
        "water": return household.water
        "wood": return household.wood
        "stone": return household.stone
        "tools": return household.tools
        "currency": return household.currency
        "waste": return household.waste
        _: return 0.0

func _set_household_value(household, resource: String, value: float) -> void:
    match resource:
        "food": household.food = value
        "water": household.water = value
        "wood": household.wood = value
        "stone": household.stone = value
        "tools": household.tools = value
        "currency": household.currency = value
        "waste": household.waste = value
