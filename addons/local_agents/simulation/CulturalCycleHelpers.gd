extends RefCounted
class_name LocalAgentsCulturalCycleHelpers

static func driver_json_schema() -> Dictionary:
	return {
		"type": "object",
		"required": ["drivers"],
		"properties": {
			"drivers": {
				"type": "array",
			},
		},
	}

static func compact_context_for_prompt(context_snapshot: Dictionary) -> Dictionary:
	var households: Array = context_snapshot.get("households", [])
	var compact_households: Array = []
	for row_variant in households:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		compact_households.append({
			"household_id": String(row.get("household_id", "")),
			"member_count": int(row.get("member_count", 0)),
			"belonging_index": snappedf(float(row.get("belonging_index", 0.0)), 0.01),
			"active_structures": int(row.get("active_structures", 0)),
			"food": snappedf(float(row.get("food", 0.0)), 0.01),
			"water": snappedf(float(row.get("water", 0.0)), 0.01),
			"currency": snappedf(float(row.get("currency", 0.0)), 0.01),
			"biome": String(row.get("biome", "plains")),
			"temperature": snappedf(float(row.get("temperature", 0.5)), 0.01),
			"water_reliability": snappedf(float(row.get("water_reliability", 0.5)), 0.01),
		})
	if compact_households.size() > 8:
		compact_households.resize(8)

	var recent_events: Array = context_snapshot.get("recent_events", [])
	var compact_events: Array = []
	for row_variant in recent_events:
		if compact_events.size() >= 20:
			break
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		compact_events.append({
			"event_type": String(row.get("event_type", "")),
			"scope": String(row.get("scope", "")),
			"owner_id": String(row.get("owner_id", "")),
			"kind": String(row.get("kind", "")),
			"magnitude": snappedf(float(row.get("magnitude", 0.0)), 0.01),
		})
	var living_entities: Array = context_snapshot.get("living_entities", [])
	var compact_entities: Array = []
	for row_variant in living_entities:
		if compact_entities.size() >= 24:
			break
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		compact_entities.append({
			"entity_id": String(row.get("entity_id", "")),
			"display_kind": String(row.get("display_kind", "")),
			"taxonomy_path": row.get("taxonomy_path", []),
			"ownership_weight": snappedf(float(row.get("ownership_weight", 0.0)), 0.01),
			"belonging_weight": snappedf(float(row.get("belonging_weight", 0.0)), 0.01),
			"gather_tendency": snappedf(float(row.get("gather_tendency", 0.0)), 0.01),
			"mobility": snappedf(float(row.get("mobility", 0.0)), 0.01),
			"tags": row.get("tags", []),
		})

	return {
		"community": context_snapshot.get("community", {}),
		"households": compact_households,
		"living_entities": compact_entities,
		"recent_events": compact_events,
	}

static func heuristic_driver_payload(context_snapshot: Dictionary) -> Array:
	var drivers: Array = []
	var households: Array = context_snapshot.get("households", [])
	var global_water_stress = 0.0
	var global_food_stress = 0.0
	var belonging_pressure = 0.0
	var ownership_pressure = 0.0
	var bone_signal = 0.0
	var animal_collect_pressure = 0.0
	var plant_food_pressure = 0.0
	var living_ownership_pressure = 0.0
	for row_variant in households:
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var household_id = String(row.get("household_id", ""))
		var water_reliability = clampf(float(row.get("water_reliability", 0.5)), 0.0, 1.0)
		var food = maxf(0.0, float(row.get("food", 0.0)))
		var belonging = clampf(float(row.get("belonging_index", 0.0)) / 3.0, 0.0, 1.0)
		var structures = maxi(0, int(row.get("active_structures", 0)))
		var bone_density = clampf(float(row.get("bone_signal", 0.0)), 0.0, 1.0)
		global_water_stress += (1.0 - water_reliability)
		global_food_stress += clampf((2.4 - food) / 2.4, 0.0, 1.0)
		belonging_pressure += belonging
		ownership_pressure += clampf(float(structures) * 0.25 + belonging * 0.25, 0.0, 1.0)
		bone_signal += bone_density
		if household_id != "":
			drivers.append({
				"label": "household_continuity",
				"topic": "kinship_continuity",
				"gain_loss": belonging * 2.0 - 1.0,
				"salience": clampf(0.3 + absf((belonging * 2.0 - 1.0)) * 0.6, 0.0, 1.0),
				"scope": "household",
				"owner_id": household_id,
				"tags": ["belonging", "kinship"],
				"summary": "Household continuity signal",
			})
	if households.size() > 0:
		var inv_count = float(households.size())
		global_water_stress /= inv_count
		global_food_stress /= inv_count
		belonging_pressure /= inv_count
		ownership_pressure /= inv_count
		bone_signal /= inv_count
	var living_entities: Array = context_snapshot.get("living_entities", [])
	var entity_count = 0
	for entity_variant in living_entities:
		if not (entity_variant is Dictionary):
			continue
		var row = entity_variant as Dictionary
		var gather_tendency = clampf(float(row.get("gather_tendency", 0.0)), 0.0, 1.0)
		var ownership_weight = clampf(float(row.get("ownership_weight", 0.0)), 0.0, 1.0)
		var taxonomy: Array = row.get("taxonomy_path", [])
		var taxonomy_key = ""
		if not taxonomy.is_empty():
			var parts: Array = []
			for token_variant in taxonomy:
				parts.append(String(token_variant))
			taxonomy_key = "/".join(PackedStringArray(parts))
		entity_count += 1
		living_ownership_pressure += ownership_weight
		if taxonomy_key.contains("/animal/") and gather_tendency > 0.0:
			animal_collect_pressure += gather_tendency
		if taxonomy_key.contains("/plant/"):
			plant_food_pressure += clampf(float(row.get("belonging_weight", 0.0)), 0.0, 1.0)
	if entity_count > 0:
		animal_collect_pressure /= float(entity_count)
		plant_food_pressure /= float(entity_count)
		living_ownership_pressure /= float(entity_count)
	drivers.append({
		"label": "water_security",
		"topic": "water_route_reliability",
		"gain_loss": 1.0 - global_water_stress * 2.0,
		"salience": clampf(0.35 + global_water_stress * 0.65, 0.0, 1.0),
		"scope": "settlement",
		"owner_id": "",
		"tags": ["water", "ownership"],
		"summary": "Shared water access pressure",
	})
	drivers.append({
		"label": "food_security",
		"topic": "safe_foraging_zones",
		"gain_loss": 1.0 - global_food_stress * 2.0,
		"salience": clampf(0.34 + global_food_stress * 0.66, 0.0, 1.0),
		"scope": "settlement",
		"owner_id": "",
		"tags": ["food", "bone"],
		"summary": "Shared diet pressure",
	})
	drivers.append({
		"label": "belonging_order",
		"topic": "belonging_oath",
		"gain_loss": clampf(belonging_pressure * 2.0 - 1.0 + (living_ownership_pressure - 0.5) * 0.2, -1.0, 1.0),
		"salience": clampf(0.28 + absf(belonging_pressure * 2.0 - 1.0) * 0.62 + living_ownership_pressure * 0.2, 0.0, 1.0),
		"scope": "settlement",
		"owner_id": "",
		"tags": ["belonging", "ownership", "ritual"],
		"summary": "Belonging and ownership norm pressure",
	})
	if animal_collect_pressure > 0.05:
		drivers.append({
			"label": "collecting_patterns",
			"topic": "ownership_boundary",
			"gain_loss": clampf(animal_collect_pressure * 1.4 - 0.5, -1.0, 1.0),
			"salience": clampf(0.2 + animal_collect_pressure * 0.7, 0.0, 1.0),
			"scope": "settlement",
			"owner_id": "",
			"tags": ["ownership", "food"],
			"summary": "Collecting pressure from non-human foragers",
		})
	if plant_food_pressure > 0.05:
		drivers.append({
			"label": "plant_food_dependence",
			"topic": "safe_foraging_zones",
			"gain_loss": clampf(plant_food_pressure * 1.6 - 0.55, -1.0, 1.0),
			"salience": clampf(0.25 + plant_food_pressure * 0.6, 0.0, 1.0),
			"scope": "settlement",
			"owner_id": "",
			"tags": ["food", "belonging"],
			"summary": "Dependence on nearby edible plants",
		})
	if bone_signal > 0.08:
		drivers.append({
			"label": "bone_memory_craft",
			"topic": "bone_craft_memory",
			"gain_loss": clampf(bone_signal * 1.5, -1.0, 1.0),
			"salience": clampf(0.22 + bone_signal * 0.74, 0.0, 1.0),
			"scope": "settlement",
			"owner_id": "",
			"tags": ["bone", "craft", "food"],
			"summary": "Bone-derived continuity memory",
		})
	return drivers

static func sanitize_drivers(rows: Array) -> Array:
	var out: Array = []
	for row_variant in rows:
		if out.size() >= 12:
			break
		if not (row_variant is Dictionary):
			continue
		var row = row_variant as Dictionary
		var topic = String(row.get("topic", "")).strip_edges()
		if topic == "":
			continue
		var scope = String(row.get("scope", "settlement")).strip_edges()
		if scope != "household":
			scope = "settlement"
		var gain_loss = clampf(float(row.get("gain_loss", 0.0)), -1.0, 1.0)
		var salience = clampf(float(row.get("salience", 0.0)), 0.0, 1.0)
		var tags: Array = row.get("tags", [])
		var clean_tags: Array = []
		for tag_variant in tags:
			var tag = String(tag_variant).strip_edges()
			if tag == "":
				continue
			if not clean_tags.has(tag):
				clean_tags.append(tag)
		out.append({
			"label": String(row.get("label", "cultural_shift")).strip_edges(),
			"topic": topic,
			"gain_loss": gain_loss,
			"salience": salience,
			"scope": scope,
			"owner_id": String(row.get("owner_id", "")).strip_edges(),
			"tags": clean_tags,
			"summary": String(row.get("summary", "")).strip_edges(),
		})
	if out.is_empty():
		out.append({
			"label": "continuity_pressure",
			"topic": "kinship_continuity",
			"gain_loss": 0.0,
			"salience": 0.35,
			"scope": "settlement",
			"owner_id": "",
			"tags": ["belonging", "ritual"],
			"summary": "Baseline continuity signal",
		})
	return out
