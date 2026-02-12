extends RefCounted
class_name LocalAgentsIndividualLedgerSystem

const StateScript = preload("res://addons/local_agents/configuration/parameters/simulation/VillagerEconomyStateResource.gd")
const InventoryScript = preload("res://addons/local_agents/configuration/parameters/simulation/VillagerInventoryResource.gd")

func initial_individual_ledger(npc_id: String):
    var state = StateScript.new()
    state.npc_id = npc_id
    if state.inventory == null:
        state.inventory = InventoryScript.new()
    state.inventory.food = 0.6
    state.inventory.water = 0.6
    state.inventory.currency = 0.5
    state.inventory.tools = 0.1
    state.energy = 1.0
    state.health = 1.0
    state.wage_due = 0.0
    state.moved_total_weight = 0.0
    return state

func distribute_from_household(state, household_ledger, transfer_ratio: float = 0.25):
    var out = state.duplicate(true)
    var inv = _inv(out)
    var ratio := clampf(transfer_ratio, 0.0, 1.0)
    inv.food += household_ledger.food * ratio * 0.05
    inv.water += household_ledger.water * ratio * 0.05
    inv.tools += household_ledger.tools * ratio * 0.03
    inv.currency += household_ledger.currency * ratio * 0.04
    return out

func consume_personal(state, transfer_rules):
    var out = state.duplicate(true)
    var inv = _inv(out)
    inv.food = maxf(0.0, inv.food - transfer_rules.individual_food_consumption)
    inv.water = maxf(0.0, inv.water - transfer_rules.individual_water_consumption)
    out.energy = clampf(out.energy - transfer_rules.individual_energy_consumption, 0.0, 1.0)
    inv.waste += transfer_rules.individual_waste_generation
    if inv.food < 0.05 or inv.water < 0.05:
        out.health = clampf(out.health - 0.01, 0.0, 1.0)
    return out

func pay_wage(state, amount: float):
    var out = state.duplicate(true)
    var inv = _inv(out)
    var wage := maxf(0.0, amount)
    inv.currency += wage
    out.wage_due = maxf(0.0, out.wage_due - wage)
    return out

func ensure_bounds(state):
    var out = state.duplicate(true)
    var inv = _inv(out)
    inv.food = maxf(0.0, inv.food)
    inv.water = maxf(0.0, inv.water)
    inv.wood = maxf(0.0, inv.wood)
    inv.stone = maxf(0.0, inv.stone)
    inv.tools = maxf(0.0, inv.tools)
    inv.currency = maxf(0.0, inv.currency)
    inv.waste = maxf(0.0, inv.waste)
    inv.carried_food = maxf(0.0, inv.carried_food)
    inv.carried_water = maxf(0.0, inv.carried_water)
    inv.carried_wood = maxf(0.0, inv.carried_wood)
    inv.carried_stone = maxf(0.0, inv.carried_stone)
    inv.carried_tools = maxf(0.0, inv.carried_tools)
    inv.carried_currency = maxf(0.0, inv.carried_currency)
    inv.carried_weight = maxf(0.0, inv.carried_weight)
    out.wage_due = maxf(0.0, out.wage_due)
    out.moved_total_weight = maxf(0.0, out.moved_total_weight)
    out.energy = clampf(out.energy, 0.0, 1.0)
    out.health = clampf(out.health, 0.0, 1.0)
    return out

func apply_carry_assignment(state, assignment: Dictionary, assignment_weight: float):
    var out = state.duplicate(true)
    var inv = _inv(out)
    inv.carried_food = maxf(0.0, float(assignment.get("food", 0.0)))
    inv.carried_water = maxf(0.0, float(assignment.get("water", 0.0)))
    inv.carried_wood = maxf(0.0, float(assignment.get("wood", 0.0)))
    inv.carried_stone = maxf(0.0, float(assignment.get("stone", 0.0)))
    inv.carried_tools = maxf(0.0, float(assignment.get("tools", 0.0)))
    inv.carried_currency = maxf(0.0, float(assignment.get("currency", 0.0)))
    inv.carried_weight = maxf(0.0, assignment_weight)
    return out

func complete_carry_delivery(state):
    var out = state.duplicate(true)
    var inv = _inv(out)
    var moved := maxf(0.0, inv.carried_weight)
    out.moved_total_weight += moved
    inv.carried_food = 0.0
    inv.carried_water = 0.0
    inv.carried_wood = 0.0
    inv.carried_stone = 0.0
    inv.carried_tools = 0.0
    inv.carried_currency = 0.0
    inv.carried_weight = 0.0
    return out

func _inv(state):
    if state.inventory == null:
        state.inventory = InventoryScript.new()
    return state.inventory
