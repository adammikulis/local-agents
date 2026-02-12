@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")
const StateHasherScript = preload("res://addons/local_agents/simulation/SimulationStateHasher.gd")

func run_test(tree: SceneTree) -> bool:
    var controller_a = SimulationControllerScript.new()
    var controller_b = SimulationControllerScript.new()
    tree.get_root().add_child(controller_a)
    tree.get_root().add_child(controller_b)

    controller_a.configure("seed-ledger", false, false)
    controller_b.configure("seed-ledger", false, false)
    controller_a.set_cognition_features(false, false, false)
    controller_b.set_cognition_features(false, false, false)

    controller_a.register_villager("npc_l1", "L1", {"household_id": "home_a"})
    controller_a.register_villager("npc_l2", "L2", {"household_id": "home_a"})
    controller_a.register_villager("npc_l3", "L3", {"household_id": "home_b"})

    controller_b.register_villager("npc_l1", "L1", {"household_id": "home_a"})
    controller_b.register_villager("npc_l2", "L2", {"household_id": "home_a"})
    controller_b.register_villager("npc_l3", "L3", {"household_id": "home_b"})

    var hasher = StateHasherScript.new()
    var hashes_a: Array = []
    var hashes_b: Array = []

    for tick in range(1, 121):
        var result_a: Dictionary = controller_a.process_tick(tick, 1.0)
        var result_b: Dictionary = controller_b.process_tick(tick, 1.0)
        hashes_a.append(hasher.hash_state(result_a))
        hashes_b.append(hasher.hash_state(result_b))

        var state_a: Dictionary = result_a.get("state", {})
        if not _check_non_negative_ledgers(state_a):
            push_error("Ledger invariant failed at tick %d" % tick)
            controller_a.queue_free()
            controller_b.queue_free()
            return false

    controller_a.queue_free()
    controller_b.queue_free()

    if hashes_a != hashes_b:
        push_error("Resource ledger deterministic replay mismatch")
        return false

    print("Simulation resource ledger test passed")
    return true

func _check_non_negative_ledgers(state: Dictionary) -> bool:
    var community: Dictionary = state.get("community_ledger", {})
    for key in ["food", "water", "wood", "stone", "tools", "currency", "labor_pool"]:
        if float(community.get(key, 0.0)) < -0.000001:
            return false

    var households: Dictionary = state.get("household_ledgers", {})
    for household_id in households.keys():
        var household: Dictionary = households.get(household_id, {})
        for key in ["food", "water", "wood", "stone", "tools", "currency", "debt"]:
            if float(household.get(key, 0.0)) < -0.000001:
                return false

    var individuals: Dictionary = state.get("individual_ledgers", {})
    for npc_id in individuals.keys():
        var individual: Dictionary = individuals.get(npc_id, {})
        var inventory: Dictionary = individual.get("inventory", {})
        for key in ["food", "water", "currency", "tools", "waste"]:
            if float(inventory.get(key, 0.0)) < -0.000001:
                return false
        if float(individual.get("wage_due", 0.0)) < -0.000001:
            return false
    return true
