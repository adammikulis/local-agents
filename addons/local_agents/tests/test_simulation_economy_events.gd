@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")

func run_test(tree: SceneTree) -> bool:
    var controller = SimulationControllerScript.new()
    tree.get_root().add_child(controller)

    controller.configure("seed-economy-events", false, false)
    controller.set_cognition_features(false, false, false)
    controller.register_villager("npc_e1", "E1", {"household_id": "home_e1", "profession": "farmer"})
    controller.register_villager("npc_e2", "E2", {"household_id": "home_e1", "profession": "merchant"})
    controller.register_villager("npc_e3", "E3", {"household_id": "home_e2", "profession": "woodcutter"})

    for tick in range(1, 33):
        var result: Dictionary = controller.process_tick(tick, 1.0)
        if not bool(result.get("ok", true)):
            push_error("Simulation tick failed at %d: %s" % [tick, String(result.get("error", ""))])
            controller.queue_free()
            return false

    var store = controller.get("_store")
    var events: Array = store.list_resource_events(controller.world_id, controller.active_branch_id, 1, 33)
    controller.queue_free()

    if events.is_empty():
        push_error("Expected economy resource events but found none")
        return false

    var has_production := false
    var has_trade := false
    var has_waste := false
    var has_market_price := false
    var last_tick := -1
    var last_seq := -1

    for event_variant in events:
        if not (event_variant is Dictionary):
            continue
        var event: Dictionary = event_variant
        var tick := int(event.get("tick", -1))
        var seq := int(event.get("sequence", -1))
        var event_type := String(event.get("event_type", ""))
        var payload: Dictionary = event.get("payload", {})

        if tick < last_tick:
            push_error("Resource events not sorted by tick")
            return false
        if tick == last_tick and seq < last_seq:
            push_error("Resource events not sorted by sequence")
            return false
        last_tick = tick
        last_seq = seq

        if event_type == "sim_production_event":
            has_production = true
        if event_type == "sim_transfer_event":
            var kind := String(payload.get("kind", ""))
            if kind == "market_trade":
                has_trade = true
            if kind == "waste_processing":
                has_waste = true
            if kind == "market_price_update":
                has_market_price = true
                var prices: Dictionary = payload.get("prices", {})
                for key in prices.keys():
                    if float(prices[key]) <= 0.0:
                        push_error("Invalid non-positive market price for %s" % String(key))
                        return false

    if not has_production:
        push_error("Missing production events")
        return false
    if not has_trade:
        push_error("Missing market trade events")
        return false
    if not has_waste:
        push_error("Missing waste processing events")
        return false
    if not has_market_price:
        push_error("Missing market price update events")
        return false

    print("Simulation economy events test passed")
    return true
