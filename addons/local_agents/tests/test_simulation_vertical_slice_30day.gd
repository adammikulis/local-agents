@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")

func run_test(tree: SceneTree) -> bool:
	var a = SimulationControllerScript.new()
	var b = SimulationControllerScript.new()
	var c = SimulationControllerScript.new()
	tree.get_root().add_child(a)
	tree.get_root().add_child(b)
	tree.get_root().add_child(c)

	a.configure("seed-vertical-slice-30day", false, false)
	b.configure("seed-vertical-slice-30day", false, false)
	c.configure("seed-vertical-slice-30day", false, false)
	a.set_cognition_features(false, false, false)
	b.set_cognition_features(false, false, false)
	c.set_cognition_features(false, false, false)

	for i in range(0, 8):
		var npc_id = "npc_vs_%d" % i
		var household_id = "home_vs_%d" % int(i / 2)
		var payload = {"household_id": household_id}
		a.register_villager(npc_id, "VS_%d" % i, payload)
		b.register_villager(npc_id, "VS_%d" % i, payload)
		c.register_villager(npc_id, "VS_%d" % i, payload)

	var cues = {
		"oral_topic_drivers": {
			"water_route_reliability": {"salience": 0.92, "gain_loss": 0.88, "tags": ["water", "ritual"]},
			"ritual_obligation": {"salience": 0.85, "gain_loss": 0.82, "tags": ["ritual", "belonging"]},
			"ownership_boundary": {"salience": 0.72, "gain_loss": 0.67, "tags": ["ownership", "belonging"]},
		},
	}
	a.set_culture_context_cues(cues)
	b.set_culture_context_cues(cues)

	var sig_a: Array = []
	var sig_b: Array = []
	var sig_c: Array = []
	var final_a: Dictionary = {}
	var final_c: Dictionary = {}
	for tick in range(1, 721):
		var ra: Dictionary = a.process_tick(tick, 1.0)
		var rb: Dictionary = b.process_tick(tick, 1.0)
		var rc: Dictionary = c.process_tick(tick, 1.0)
		if tick % 12 == 0:
			sig_a.append(_compact_signature(ra.get("state", {})))
			sig_b.append(_compact_signature(rb.get("state", {})))
			sig_c.append(_compact_signature(rc.get("state", {})))
		final_a = ra.get("state", {})
		final_c = rc.get("state", {})

	if sig_a != sig_b:
		push_error("30-day vertical slice determinism mismatch for identical seed and choices")
		a.queue_free()
		b.queue_free()
		c.queue_free()
		return false
	if sig_a == sig_c:
		push_error("Expected culture cues to create divergent 30-day timeline")
		a.queue_free()
		b.queue_free()
		c.queue_free()
		return false

	var structures = _total_structures(final_a.get("structures", {}))
	if structures < 4:
		push_error("Expected non-trivial settlement growth over 30 days")
		a.queue_free()
		b.queue_free()
		c.queue_free()
		return false

	var community: Dictionary = final_a.get("community_ledger", {})
	if float(community.get("food", 0.0)) <= 0.0:
		push_error("Expected community to sustain positive food over 30-day slice")
		a.queue_free()
		b.queue_free()
		c.queue_free()
		return false
	if float(community.get("water", 0.0)) <= 0.0:
		push_error("Expected community to sustain positive water over 30-day slice")
		a.queue_free()
		b.queue_free()
		c.queue_free()
		return false

	var policy: Dictionary = final_a.get("cultural_policy", {})
	if float(policy.get("water_conservation", 0.0)) <= 0.0:
		push_error("Expected cultural policy to influence 30-day slice outcomes")
		a.queue_free()
		b.queue_free()
		c.queue_free()
		return false

	a.queue_free()
	b.queue_free()
	c.queue_free()
	print("Vertical slice 30-day deterministic test passed")
	return true

func _compact_signature(state: Dictionary) -> Dictionary:
	var community: Dictionary = state.get("community_ledger", {})
	var flow_network: Dictionary = state.get("flow_network", {})
	var policy: Dictionary = state.get("cultural_policy", {})
	return {
		"tick": int(state.get("tick", 0)),
		"structures": _total_structures(state.get("structures", {})),
		"edge_count": int(flow_network.get("edge_count", 0)),
		"partial_delivery_count": int(state.get("partial_delivery_count", 0)),
		"food": snappedf(float(community.get("food", 0.0)), 0.001),
		"water": snappedf(float(community.get("water", 0.0)), 0.001),
		"tools": snappedf(float(community.get("tools", 0.0)), 0.001),
		"waste": snappedf(float(community.get("waste", 0.0)), 0.001),
		"water_conservation": snappedf(float(policy.get("water_conservation", 0.0)), 0.001),
		"water_taboo_compliance": snappedf(float(policy.get("water_taboo_compliance", 0.0)), 0.001),
		"route_discipline": snappedf(float(policy.get("route_discipline", 0.0)), 0.001),
	}

func _total_structures(structures_by_household: Dictionary) -> int:
	var count = 0
	var household_ids = structures_by_household.keys()
	household_ids.sort_custom(func(a, b): return String(a) < String(b))
	for household_id_variant in household_ids:
		count += int((structures_by_household.get(String(household_id_variant), []) as Array).size())
	return count
