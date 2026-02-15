extends RefCounted
class_name LocalAgentsCulturalCycleTopicRuntime

func run_oral_schedule(system, tick: int, graph, rng, world_id: String, branch_id: String, household_members: Dictionary, context_snapshot: Dictionary, context_cues: Dictionary, drivers: Array) -> Array:
	var rows: Array = []
	var world_day = int(tick / 24)
	var household_ids = household_members.keys()
	household_ids.sort()
	for household_id_variant in household_ids:
		var household_id = String(household_id_variant)
		var members: Array = household_members.get(household_id, [])
		if members.size() < 2:
			continue
		members.sort()
		var speaker_id = String(members[0])
		var listener_index = 1 + rng.randi_range("oral_listener", household_id, branch_id, tick, 0, members.size() - 2)
		var listener_id = String(members[listener_index])
		var household_context: Dictionary = household_context_for(household_id, context_snapshot)
		var topic_weights = topic_weights_for_household(household_id, household_context, context_cues, drivers)
		var topic = select_weighted_topic(topic_weights, rng, household_id, branch_id, tick)
		if topic == "":
			topic = "belonging_oath"
		var signal_strength = rng.randomf("oral_signal", household_id + ":" + topic, branch_id, tick)
		var topic_salience = topic_salience(topic, household_id, drivers)
		var topic_gain_loss = topic_gain_loss(topic, household_id, drivers)
		var prior_confidence = clampf(float(system._confidence_by_topic.get(topic, 0.5)), 0.0, 1.0)
		var confidence = clampf(0.58 + signal_strength * 0.22 + prior_confidence * 0.18 + topic_salience * 0.24, 0.2, 0.99)
		system._confidence_by_topic[topic] = clampf(float(system._confidence_by_topic.get(topic, 0.5)) * 0.82 + confidence * 0.18, 0.0, 1.0)
		var item_id = "ok:%s:%s:%s:%s:%d" % [world_id, branch_id, household_id, topic, world_day]
		var drift = compute_detail_drift(topic, household_id, branch_id, tick, confidence, topic_salience, topic_gain_loss, rng)
		var content = topic_content(topic, household_id, household_context, drivers, drift)
		var motifs = topic_motifs(topic)
		var write = graph.record_oral_knowledge(
			item_id,
			listener_id,
			topic,
			content,
			confidence,
			motifs,
			world_day,
			{
				"source_kind": "oral_transfer",
				"source_id": "household:%s" % household_id,
				"speaker_npc_id": speaker_id,
				"transmission_hops": 1,
				"retained_confidence": prior_confidence,
				"detail_drift": drift,
				"motif_anchor": topic,
			}
		)
		if not bool(write.get("ok", false)):
			continue
		var lineage_key = "%s|%s" % [household_id, topic]
		var previous_id = String(system._oral_last_item.get(lineage_key, ""))
		if previous_id != "" and previous_id != item_id:
			graph.link_oral_knowledge_lineage(previous_id, item_id, speaker_id, listener_id, 1, world_day)
		system._oral_last_item[lineage_key] = item_id
		rows.append({
			"household_id": household_id,
			"speaker_npc_id": speaker_id,
			"listener_npc_id": listener_id,
			"knowledge_id": item_id,
			"topic": topic,
			"content": content,
			"motifs": motifs.duplicate(true),
			"confidence": confidence,
			"salience": topic_salience,
			"gain_loss": topic_gain_loss,
			"retained_confidence": prior_confidence,
			"detail_drift": drift,
			"metadata": {
				"salience": topic_salience,
				"gain_loss": topic_gain_loss,
				"retained_confidence": prior_confidence,
				"detail_drift": drift,
				"motif_anchor": topic,
			},
		})
	return rows

func run_ritual_schedule(tick: int, graph, rng, world_id: String, branch_id: String, sacred_site_id: String, npc_ids: Array, drivers: Array) -> Array:
	if npc_ids.is_empty():
		return []
	var participants = npc_ids.duplicate()
	participants.sort()
	if participants.size() > 4:
		participants.resize(4)
	var world_day = int(tick / 24)
	var ritual_id = "ritual:%s:%s:%d" % [world_id, branch_id, world_day]
	var ambient = rng.randomf("ritual_cohesion", sacred_site_id, branch_id, tick)
	var driver_intensity = ritual_driver_intensity(drivers)
	var ritual_gain_loss = ritual_gain_loss(drivers)
	var cohesion = clampf(0.34 + ambient * 0.28 + driver_intensity * 0.38, 0.2, 0.99)
	var dominant = dominant_driver_label(drivers)
	var write = graph.record_ritual_event(
		ritual_id,
		sacred_site_id,
		world_day,
		participants,
		{
			"cohesion": cohesion,
			"tick": tick,
			"driver": dominant,
			"salience": driver_intensity,
			"gain_loss": ritual_gain_loss,
		},
		{"source_kind": "ritual_cycle"}
	)
	if not bool(write.get("ok", false)):
		return []
	return [{
		"ritual_id": ritual_id,
		"site_id": sacred_site_id,
		"world_day": world_day,
		"participants": participants,
		"cohesion": cohesion,
		"driver": dominant,
		"salience": driver_intensity,
		"gain_loss": ritual_gain_loss,
		"metadata": {
			"salience": driver_intensity,
			"gain_loss": ritual_gain_loss,
		},
	}]

func decay_confidence(confidence_by_topic: Dictionary) -> void:
	var keys = confidence_by_topic.keys()
	keys.sort_custom(func(a, b): return String(a) < String(b))
	for key in keys:
		var topic = String(key)
		confidence_by_topic[topic] = clampf(float(confidence_by_topic.get(topic, 0.0)) * 0.96, 0.0, 1.0)

func topic_content(topic: String, household_id: String, household_context: Dictionary, drivers: Array, detail_drift: float = 0.0) -> String:
	var base = topic_base_content(topic, household_id, household_context, drivers)
	var detail = topic_detail_variant(topic, detail_drift)
	if detail == "":
		return base
	return "%s %s" % [base, detail]

func topic_base_content(topic: String, household_id: String, household_context: Dictionary, drivers: Array) -> String:
	var driver_hint = dominant_driver_label(drivers)
	var biome = String(household_context.get("biome", "plains"))
	match topic:
		"water_route_reliability":
			return "Follow the reliable channel near %s before midday." % household_id
		"safe_foraging_zones":
			return "Gather roots along the safer slope edges around %s." % household_id
		"seasonal_environmental_cues":
			return "Low morning haze means stronger valley winds by dusk."
		"toolcraft_recipe":
			return "Harden stone flakes in brief hearth heat before binding."
		"ritual_obligation":
			return "Bring clean water first before the spring-circle rite."
		"belonging_oath":
			return "Who keeps hearth and stores in %s belongs to its future." % household_id
		"kinship_continuity":
			return "Keep names and duties remembered so %s remains one body." % household_id
		"ownership_boundary":
			return "Mark what %s guards and what is shared, then keep the boundary." % household_id
		"bone_craft_memory":
			return "Bone from hard-won meat in %s is kept, carved, and taught." % household_id
		_:
			return "Remember %s paths in the %s; hold to %s." % [household_id, biome, driver_hint]

func topic_detail_variant(topic: String, detail_drift: float) -> String:
	var motifs = topic_motifs(topic)
	var anchor = String(motifs[0]) if not motifs.is_empty() else topic
	var variants: Array = []
	match topic:
		"water_route_reliability":
			variants = [
				"Keep the %s teaching unchanged." % anchor,
				"Some say the current bends later than before, but the %s teaching stays." % anchor,
				"Others place the crossing farther upriver, yet the %s teaching remains." % anchor,
			]
		"safe_foraging_zones":
			variants = [
				"Hold to the %s teaching." % anchor,
				"Some retell it with a steeper ridge marker while keeping the %s teaching." % anchor,
				"Others swap the tree landmark, but keep the %s teaching intact." % anchor,
			]
		"seasonal_environmental_cues":
			variants = [
				"Keep the %s teaching." % anchor,
				"Some now watch the haze later in the day, still within the %s teaching." % anchor,
				"Others retell the wind turn at dusk, while preserving the %s teaching." % anchor,
			]
		"toolcraft_recipe":
			variants = [
				"Keep the %s teaching." % anchor,
				"Some shorten the heating count but still follow the %s teaching." % anchor,
				"Others bind with different fiber lengths while preserving the %s teaching." % anchor,
			]
		"ritual_obligation":
			variants = [
				"Keep the %s teaching." % anchor,
				"Some place offerings in a different order while keeping the %s teaching." % anchor,
				"Others begin earlier at dawn but preserve the %s teaching." % anchor,
			]
		"belonging_oath":
			variants = [
				"Keep the %s teaching." % anchor,
				"Some name elders first, still preserving the %s teaching." % anchor,
				"Others retell it by hearth order, while keeping the %s teaching." % anchor,
			]
		"kinship_continuity":
			variants = [
				"Keep the %s teaching." % anchor,
				"Some recite lineages from younger kin first, preserving the %s teaching." % anchor,
				"Others retell duties before names, while keeping the %s teaching." % anchor,
			]
		"ownership_boundary":
			variants = [
				"Keep the %s teaching." % anchor,
				"Some shift boundary stones by one pace, still honoring the %s teaching." % anchor,
				"Others retell marker order differently while preserving the %s teaching." % anchor,
			]
		"bone_craft_memory":
			variants = [
				"Keep the %s teaching." % anchor,
				"Some retell different carving strokes while preserving the %s teaching." % anchor,
				"Others change grip sequence, but keep the %s teaching intact." % anchor,
			]
		_:
			variants = ["Keep the %s teaching." % anchor]
	var index = mini(int(floor(detail_drift * 3.0)), variants.size() - 1)
	return String(variants[index])

func compute_detail_drift(topic: String, household_id: String, branch_id: String, tick: int, confidence: float, salience: float, gain_loss: float, rng) -> float:
	var instability = clampf(1.0 - confidence, 0.0, 1.0)
	var pressure = absf(clampf(gain_loss, -1.0, 1.0))
	var drift_threshold = clampf(0.14 + instability * 0.54 + pressure * 0.24 - salience * 0.16, 0.08, 0.92)
	var roll = rng.randomf("oral_detail_drift_roll", household_id + ":" + topic, branch_id, tick)
	if roll >= drift_threshold:
		return 0.0
	var span = clampf(drift_threshold - roll, 0.0, drift_threshold)
	if drift_threshold <= 0.0:
		return 0.0
	return clampf(0.34 + (span / drift_threshold) * 0.66, 0.0, 1.0)

func topic_motifs(topic: String) -> Array:
	match topic:
		"water_route_reliability":
			return [topic, "water"]
		"safe_foraging_zones":
			return [topic, "food"]
		"seasonal_environmental_cues":
			return [topic, "environment"]
		"toolcraft_recipe":
			return [topic, "craft"]
		"ritual_obligation":
			return [topic, "ritual"]
		"belonging_oath":
			return [topic, "belonging"]
		"kinship_continuity":
			return [topic, "kinship"]
		"ownership_boundary":
			return [topic, "ownership"]
		"bone_craft_memory":
			return [topic, "bone"]
		_:
			return [topic]

func retention_metrics(confidence_by_topic: Dictionary) -> Dictionary:
	var by_topic: Dictionary = {}
	var keys = confidence_by_topic.keys()
	keys.sort_custom(func(a, b): return String(a) < String(b))
	var total = 0.0
	for key_variant in keys:
		var topic = String(key_variant)
		var value = clampf(float(confidence_by_topic.get(topic, 0.0)), 0.0, 1.0)
		by_topic[topic] = snappedf(value, 0.001)
		total += value
	var count = by_topic.size()
	var average = total / float(count) if count > 0 else 0.0
	return {
		"retention_by_topic": by_topic,
		"summary": {
			"topic_count": count,
			"average_retention": snappedf(clampf(average, 0.0, 1.0), 0.001),
		},
	}

func household_context_for(household_id: String, context_snapshot: Dictionary) -> Dictionary:
	var households: Array = context_snapshot.get("households", [])
	for row_variant in households:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		if String(row.get("household_id", "")) == household_id:
			return row
	return {}

func topic_weights_for_household(household_id: String, household_context: Dictionary, context_cues: Dictionary, drivers: Array) -> Dictionary:
	var weights: Dictionary = {
		"water_route_reliability": 0.6,
		"safe_foraging_zones": 0.6,
		"seasonal_environmental_cues": 0.55,
		"toolcraft_recipe": 0.52,
		"ritual_obligation": 0.48,
		"belonging_oath": 0.64,
		"kinship_continuity": 0.57,
		"ownership_boundary": 0.59,
		"bone_craft_memory": 0.49,
	}
	var water_reliability = clampf(float(household_context.get("water_reliability", 0.5)), 0.0, 1.0)
	var food = maxf(0.0, float(household_context.get("food", 0.0)))
	var structures = maxi(0, int(household_context.get("active_structures", 0)))
	var belonging_index = clampf(float(household_context.get("belonging_index", 0.5)), 0.0, 3.0)
	weights["water_route_reliability"] = float(weights["water_route_reliability"]) + (1.0 - water_reliability) * 0.8
	weights["safe_foraging_zones"] = float(weights["safe_foraging_zones"]) + (0.9 - clampf(food / 4.0, 0.0, 0.9)) * 0.55
	weights["ownership_boundary"] = float(weights["ownership_boundary"]) + clampf(float(structures) * 0.14, 0.0, 0.5)
	weights["belonging_oath"] = float(weights["belonging_oath"]) + clampf(belonging_index * 0.18, 0.0, 0.5)
	weights["kinship_continuity"] = float(weights["kinship_continuity"]) + clampf(belonging_index * 0.12, 0.0, 0.32)
	apply_context_cues_to_topic_weights(weights, context_cues)
	for driver_variant in drivers:
		if not (driver_variant is Dictionary):
			continue
		var driver = driver_variant as Dictionary
		var scope = String(driver.get("scope", "settlement"))
		var owner_id = String(driver.get("owner_id", ""))
		if scope == "household" and owner_id != "" and owner_id != household_id:
			continue
		var salience = clampf(float(driver.get("salience", 0.0)), 0.0, 1.0)
		var gain_loss = clampf(float(driver.get("gain_loss", 0.0)), -1.0, 1.0)
		var tags: Array = driver.get("tags", [])
		var topic = String(driver.get("topic", ""))
		if topic != "" and weights.has(topic):
			weights[topic] = float(weights[topic]) + salience * 0.8 + absf(gain_loss) * 0.35
		for tag_variant in tags:
			var tag = String(tag_variant)
			match tag:
				"belonging":
					weights["belonging_oath"] = float(weights["belonging_oath"]) + salience * 0.65
					weights["kinship_continuity"] = float(weights["kinship_continuity"]) + salience * 0.44
				"ownership":
					weights["ownership_boundary"] = float(weights["ownership_boundary"]) + salience * 0.7
				"water":
					weights["water_route_reliability"] = float(weights["water_route_reliability"]) + salience * 0.68
				"food":
					weights["safe_foraging_zones"] = float(weights["safe_foraging_zones"]) + salience * 0.58
				"bone":
					weights["bone_craft_memory"] = float(weights["bone_craft_memory"]) + salience * 0.74
				"ritual":
					weights["ritual_obligation"] = float(weights["ritual_obligation"]) + salience * 0.48
				"environment":
					weights["seasonal_environmental_cues"] = float(weights["seasonal_environmental_cues"]) + salience * 0.52
				_:
					pass
	return weights

func apply_context_cues_to_topic_weights(weights: Dictionary, context_cues: Dictionary) -> void:
	var oral_topic_drivers: Dictionary = context_cues.get("oral_topic_drivers", {})
	var keys = oral_topic_drivers.keys()
	keys.sort_custom(func(a, b): return String(a) < String(b))
	for key_variant in keys:
		var topic = String(key_variant)
		if not weights.has(topic):
			continue
		var cue_variant = oral_topic_drivers.get(topic, null)
		if not (cue_variant is Dictionary):
			continue
		var cue = cue_variant as Dictionary
		var salience = clampf(float(cue.get("salience", 0.0)), 0.0, 1.0)
		var gain_loss = clampf(float(cue.get("gain_loss", 0.0)), -1.0, 1.0)
		weights[topic] = float(weights[topic]) + salience * 1.2 + absf(gain_loss) * 0.55

func select_weighted_topic(topic_weights: Dictionary, rng, household_id: String, branch_id: String, tick: int) -> String:
	var entries: Array = []
	var total = 0.0
	var keys = topic_weights.keys()
	keys.sort_custom(func(a, b): return String(a) < String(b))
	for key_variant in keys:
		var topic = String(key_variant)
		var weight = maxf(0.0001, float(topic_weights.get(topic, 0.0)))
		total += weight
		entries.append({"topic": topic, "edge": total})
	if entries.is_empty() or total <= 0.0:
		return ""
	var needle = rng.randomf("oral_topic_weighted", household_id, branch_id, tick) * total
	for row_variant in entries:
		var row = row_variant as Dictionary
		if needle <= float(row.get("edge", 0.0)):
			return String(row.get("topic", ""))
	return String((entries[entries.size() - 1] as Dictionary).get("topic", ""))

func topic_salience(topic: String, household_id: String, drivers: Array) -> float:
	var best = 0.0
	for driver_variant in drivers:
		if not (driver_variant is Dictionary):
			continue
		var row = driver_variant as Dictionary
		var scope = String(row.get("scope", "settlement"))
		var owner_id = String(row.get("owner_id", ""))
		if scope == "household" and owner_id != "" and owner_id != household_id:
			continue
		var salience = clampf(float(row.get("salience", 0.0)), 0.0, 1.0)
		if String(row.get("topic", "")) == topic:
			best = maxf(best, salience)
			continue
		var tags: Array = row.get("tags", [])
		for tag_variant in tags:
			var tag = String(tag_variant)
			if tag_matches_topic(tag, topic):
				best = maxf(best, salience * 0.92)
	return best

func tag_matches_topic(tag: String, topic: String) -> bool:
	match topic:
		"water_route_reliability":
			return tag == "water"
		"safe_foraging_zones":
			return tag == "food"
		"seasonal_environmental_cues":
			return tag == "environment"
		"toolcraft_recipe":
			return tag == "craft"
		"ritual_obligation":
			return tag == "ritual"
		"belonging_oath":
			return tag == "belonging"
		"kinship_continuity":
			return tag == "kinship"
		"ownership_boundary":
			return tag == "ownership"
		"bone_craft_memory":
			return tag == "bone"
		_:
			return false

func ritual_driver_intensity(drivers: Array) -> float:
	if drivers.is_empty():
		return 0.0
	var total = 0.0
	var count = 0
	for row_variant in drivers:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var salience = clampf(float(row.get("salience", 0.0)), 0.0, 1.0)
		var gain_loss = absf(clampf(float(row.get("gain_loss", 0.0)), -1.0, 1.0))
		total += salience * 0.7 + gain_loss * 0.3
		count += 1
	if count <= 0:
		return 0.0
	return clampf(total / float(count), 0.0, 1.0)

func ritual_gain_loss(drivers: Array) -> float:
	if drivers.is_empty():
		return 0.0
	var total = 0.0
	var weight_total = 0.0
	for row_variant in drivers:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var salience = clampf(float(row.get("salience", 0.0)), 0.0, 1.0)
		var gain_loss = clampf(float(row.get("gain_loss", 0.0)), -1.0, 1.0)
		var weight = maxf(0.05, salience)
		total += gain_loss * weight
		weight_total += weight
	if weight_total <= 0.0:
		return 0.0
	return clampf(total / weight_total, -1.0, 1.0)

func dominant_driver_label(drivers: Array) -> String:
	var winner = ""
	var best = -1.0
	for row_variant in drivers:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var salience = clampf(float(row.get("salience", 0.0)), 0.0, 1.0)
		var gain_loss = absf(clampf(float(row.get("gain_loss", 0.0)), -1.0, 1.0))
		var score = salience * 0.72 + gain_loss * 0.28
		if score > best:
			best = score
			winner = String(row.get("label", "shared_duty"))
	return winner if winner != "" else "shared_duty"

func topic_gain_loss(topic: String, household_id: String, drivers: Array) -> float:
	var total = 0.0
	var weight_total = 0.0
	for driver_variant in drivers:
		if not (driver_variant is Dictionary):
			continue
		var row = driver_variant as Dictionary
		var scope = String(row.get("scope", "settlement"))
		var owner_id = String(row.get("owner_id", ""))
		if scope == "household" and owner_id != "" and owner_id != household_id:
			continue
		var salience = clampf(float(row.get("salience", 0.0)), 0.0, 1.0)
		var gain_loss = clampf(float(row.get("gain_loss", 0.0)), -1.0, 1.0)
		var is_match = String(row.get("topic", "")) == topic
		if not is_match:
			var tags: Array = row.get("tags", [])
			for tag_variant in tags:
				if tag_matches_topic(String(tag_variant), topic):
					is_match = true
					break
		if not is_match:
			continue
		var weight = maxf(0.05, salience)
		total += gain_loss * weight
		weight_total += weight
	if weight_total <= 0.0:
		return 0.0
	return clampf(total / weight_total, -1.0, 1.0)

func driver_digest(drivers: Array) -> Dictionary:
	var dominant = dominant_driver_label(drivers)
	var intensity = ritual_driver_intensity(drivers)
	return {
		"dominant": dominant,
		"intensity": intensity,
		"count": drivers.size(),
	}
