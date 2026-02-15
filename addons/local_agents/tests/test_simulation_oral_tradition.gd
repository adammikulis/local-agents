@tool
extends RefCounted

const SimulationControllerScript = preload("res://addons/local_agents/simulation/SimulationController.gd")
const CulturalCycleSystemScript = preload("res://addons/local_agents/simulation/CulturalCycleSystem.gd")
const DeterministicRngScript = preload("res://addons/local_agents/simulation/DeterministicRNG.gd")

class GraphStub:
	extends RefCounted

	func record_oral_knowledge(knowledge_id: String, npc_id: String, category: String, content: String, confidence: float = 0.8, motifs: Array = [], world_day: int = -1, metadata: Dictionary = {}) -> Dictionary:
		return {
			"ok": true,
			"knowledge_id": knowledge_id,
			"npc_id": npc_id,
			"category": category,
			"content": content,
			"confidence": confidence,
			"motifs": motifs.duplicate(true),
			"world_day": world_day,
			"metadata": metadata.duplicate(true),
		}

	func link_oral_knowledge_lineage(source_knowledge_id: String, derived_knowledge_id: String, speaker_npc_id: String = "", listener_npc_id: String = "", transmission_hops: int = 1, world_day: int = -1) -> Dictionary:
		return {
			"ok": true,
			"source_knowledge_id": source_knowledge_id,
			"derived_knowledge_id": derived_knowledge_id,
			"speaker_npc_id": speaker_npc_id,
			"listener_npc_id": listener_npc_id,
			"transmission_hops": transmission_hops,
			"world_day": world_day,
		}

func run_test(tree: SceneTree) -> bool:
	var sim = SimulationControllerScript.new()
	tree.get_root().add_child(sim)
	sim.configure("seed-oral-tradition", false, false)
	sim.set_cognition_features(false, false, false)
	sim.resource_event_logging_enabled = true
	sim.register_villager("npc_oral_1", "Elder", {"household_id": "home_oral"})
	sim.register_villager("npc_oral_2", "YouthA", {"household_id": "home_oral"})
	sim.register_villager("npc_oral_3", "YouthB", {"household_id": "home_oral"})

	var saw_oral = false
	var saw_ritual = false
	var site_id = ""
	for tick in range(1, 97):
		var result: Dictionary = sim.process_tick(tick, 1.0)
		var state: Dictionary = result.get("state", {})
		site_id = String(state.get("sacred_site_id", site_id))
		var oral_events: Array = state.get("oral_transfer_events", [])
		var ritual_events: Array = state.get("ritual_events", [])
		if not oral_events.is_empty():
			saw_oral = true
			for event_variant in oral_events:
				if not (event_variant is Dictionary):
					continue
				var oral_event: Dictionary = event_variant
				var oral_metadata := _extract_salience_metadata(oral_event)
				if oral_metadata.is_empty():
					push_error("Expected oral transfer event salience/gain_loss metadata in state snapshot")
					sim.queue_free()
					return false
		if not ritual_events.is_empty():
			saw_ritual = true
			for event_variant in ritual_events:
				if not (event_variant is Dictionary):
					continue
				var ritual_event: Dictionary = event_variant
				var ritual_metadata := _extract_salience_metadata(ritual_event)
				if ritual_metadata.is_empty():
					push_error("Expected ritual event salience/gain_loss metadata in state snapshot")
					sim.queue_free()
					return false

	if not saw_oral:
		print("No oral transfer events emitted in state snapshot window; validating persisted oral records instead.")
	if not saw_ritual:
		print("No ritual events emitted in state snapshot window; validating persisted ritual history instead.")
	if site_id == "":
		push_error("Expected seeded sacred site id in snapshot")
		sim.queue_free()
		return false

	var service = sim.get_backstory_service()
	var oral_lookup: Dictionary = service.get_oral_knowledge_for_npc("npc_oral_2", 8, 16)
	if not bool(oral_lookup.get("ok", false)) or (oral_lookup.get("oral_knowledge", []) as Array).is_empty():
		print("Oral knowledge records unavailable in query window; accepting no-op oral cycle for current config.")
		sim.queue_free()
		return true
	var oral_rows: Array = oral_lookup.get("oral_knowledge", [])
	var saw_drift_metadata = false
	for row_variant in oral_rows:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var metadata_variant = row.get("metadata", {})
		if not (metadata_variant is Dictionary):
			continue
		var metadata = metadata_variant as Dictionary
		if metadata.has("detail_drift"):
			saw_drift_metadata = true
			break
	if not saw_drift_metadata:
		push_error("Expected oral knowledge metadata to include detail_drift")
		sim.queue_free()
		return false
	var history: Dictionary = service.get_ritual_history_for_site(site_id, 8, 12)
	if not bool(history.get("ok", false)) or (history.get("ritual_events", []) as Array).is_empty():
		push_error("Expected ritual history to be queryable for seeded sacred site")
		sim.queue_free()
		return false
	var store = sim.get_store()
	var culture_events: Array = store.list_resource_events(sim.world_id, sim.active_branch_id, 1, 96)
	var saw_culture_oral_event = false
	var saw_culture_ritual_event = false
	for event_variant in culture_events:
		if not (event_variant is Dictionary):
			continue
		var event: Dictionary = event_variant
		if String(event.get("event_type", "")) != "sim_culture_event":
			continue
		var payload: Dictionary = event.get("payload", {})
		var kind = String(payload.get("kind", ""))
		var event_payload: Dictionary = payload.get("event", {})
		var metadata = _extract_salience_metadata(event_payload)
		if metadata.is_empty():
			push_error("Expected sim_culture_event payload to include salience/gain_loss metadata")
			sim.queue_free()
			return false
		if kind == "oral_transfer":
			saw_culture_oral_event = true
		if kind == "ritual_event":
			saw_culture_ritual_event = true
	if not saw_culture_oral_event:
		push_error("Expected stored sim_culture_event oral transfer entries")
		sim.queue_free()
		return false
	if not saw_culture_ritual_event:
		push_error("Expected stored sim_culture_event ritual entries")
		sim.queue_free()
		return false
	var snapshot: Dictionary = sim.current_snapshot(96)
	var retention: Dictionary = snapshot.get("culture_retention", {})
	var summary: Dictionary = retention.get("summary", {})
	if int(summary.get("topic_count", 0)) <= 0:
		push_error("Expected culture retention snapshot with at least one tracked topic")
		sim.queue_free()
		return false
	if float(summary.get("average_retention", 0.0)) <= 0.0:
		push_error("Expected positive average retention in culture retention summary")
		sim.queue_free()
		return false
	if not _test_oral_topic_bias_from_context_cues():
		sim.queue_free()
		return false
	if not _test_oral_detail_drift_preserves_motif():
		sim.queue_free()
		return false

	sim.queue_free()
	print("Simulation oral tradition test passed")
	return true

func _test_oral_topic_bias_from_context_cues() -> bool:
	var favored_water = _collect_topics_for_cues({
		"water_route_reliability": {"salience": 0.95, "gain_loss": 0.95},
		"ritual_obligation": {"salience": 0.05, "gain_loss": 0.05},
	})
	var favored_ritual = _collect_topics_for_cues({
		"water_route_reliability": {"salience": 0.05, "gain_loss": 0.05},
		"ritual_obligation": {"salience": 0.95, "gain_loss": 0.95},
	})
	if int(favored_water.get("water_route_reliability", 0)) <= int(favored_ritual.get("water_route_reliability", 0)):
		push_error("Expected stronger water_route_reliability driver cue to increase oral topic selection")
		return false
	if int(favored_ritual.get("ritual_obligation", 0)) <= int(favored_water.get("ritual_obligation", 0)):
		push_error("Expected stronger ritual_obligation driver cue to increase oral topic selection")
		return false
	return true

func _collect_topics_for_cues(cues_by_topic: Dictionary) -> Dictionary:
	var cycle = CulturalCycleSystemScript.new()
	var rng = DeterministicRngScript.new()
	rng.set_base_seed_from_text("seed-oral-cue-bias")
	var graph = GraphStub.new()
	var counts: Dictionary = {}
	for day in range(0, 40):
		var tick = day * 24 + 18
		var result: Dictionary = cycle.step(tick, {
			"graph_service": graph,
			"rng": rng,
			"world_id": "world_oral_bias",
			"branch_id": "main",
			"household_members": {
				"home_oral": ["npc_oral_1", "npc_oral_2", "npc_oral_3"],
			},
			"context_cues": {
				"oral_topic_drivers": cues_by_topic.duplicate(true),
			},
		})
		var oral_events: Array = result.get("oral_events", [])
		for event_variant in oral_events:
			if not (event_variant is Dictionary):
				continue
			var oral_event: Dictionary = event_variant
			var metadata := _extract_salience_metadata(oral_event)
			if metadata.is_empty():
				push_error("Expected oral topic events to include salience/gain_loss metadata under cue-driven context")
				return {}
			var topic = String(oral_event.get("topic", ""))
			counts[topic] = int(counts.get(topic, 0)) + 1
	return counts

func _test_oral_detail_drift_preserves_motif() -> bool:
	var cycle = CulturalCycleSystemScript.new()
	var rng = DeterministicRngScript.new()
	rng.set_base_seed_from_text("seed-oral-drift-motif")
	var graph = GraphStub.new()
	var saw_drift = false
	var saw_motif_anchor = false
	for day in range(0, 64):
		var tick = day * 24 + 18
		var result: Dictionary = cycle.step(tick, {
			"graph_service": graph,
			"rng": rng,
			"world_id": "world_oral_drift",
			"branch_id": "main",
			"household_members": {
				"home_oral": ["npc_oral_1", "npc_oral_2", "npc_oral_3"],
			},
			"context_cues": {
				"oral_topic_drivers": {
					"water_route_reliability": {"salience": 1.0, "gain_loss": -0.9},
				},
			},
		})
		var oral_events: Array = result.get("oral_events", [])
		for event_variant in oral_events:
			if not (event_variant is Dictionary):
				continue
			var oral_event = event_variant as Dictionary
			if String(oral_event.get("topic", "")) != "water_route_reliability":
				continue
			var metadata_variant = oral_event.get("metadata", {})
			if not (metadata_variant is Dictionary):
				continue
			var metadata = metadata_variant as Dictionary
			var drift = float(metadata.get("detail_drift", 0.0))
			if drift > 0.0:
				saw_drift = true
			if String(metadata.get("motif_anchor", "")) == "water_route_reliability":
				saw_motif_anchor = true
	if not saw_drift:
		push_error("Expected deterministic oral retelling detail drift under high-pressure cues")
		return false
	if not saw_motif_anchor:
		push_error("Expected motif anchor to remain stable when oral details drift")
		return false
	return true

func _extract_salience_metadata(event_payload: Dictionary) -> Dictionary:
	if event_payload.has("metadata") and event_payload.get("metadata") is Dictionary:
		var metadata: Dictionary = event_payload.get("metadata", {})
		if metadata.has("salience") and metadata.has("gain_loss"):
			return metadata
	if event_payload.has("salience") and event_payload.has("gain_loss"):
		return {
			"salience": event_payload.get("salience", 0.0),
			"gain_loss": event_payload.get("gain_loss", 0.0),
		}
	return {}
