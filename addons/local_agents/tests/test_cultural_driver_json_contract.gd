extends RefCounted

const CulturalCycleSystemScript = preload("res://addons/local_agents/simulation/CulturalCycleSystem.gd")

func run_test(_tree: SceneTree) -> bool:
	var system = CulturalCycleSystemScript.new()
	var schema: Dictionary = system.call("_driver_json_schema")
	if String(schema.get("type", "")) != "object":
		push_error("Expected object schema for cultural drivers")
		return false
	var required_variant = schema.get("required", [])
	if not (required_variant is Array) or not (required_variant as Array).has("drivers"):
		push_error("Expected schema to require drivers")
		return false
	var properties_variant = schema.get("properties", {})
	if not (properties_variant is Dictionary):
		push_error("Expected schema properties dictionary")
		return false
	var properties: Dictionary = properties_variant
	var drivers_prop_variant = properties.get("drivers", {})
	if not (drivers_prop_variant is Dictionary):
		push_error("Expected drivers property schema")
		return false
	var drivers_prop: Dictionary = drivers_prop_variant
	if String(drivers_prop.get("type", "")) != "array":
		push_error("Expected drivers schema type=array")
		return false

	var sanitized: Array = system.call("_sanitize_drivers", [
		{
			"label": "food_signal",
			"topic": "safe_foraging_zones",
			"gain_loss": 1.8,
			"salience": -0.2,
			"scope": "household",
			"owner_id": "h1",
			"tags": ["food", "food", "", "belonging"],
			"summary": "foraging pressure",
		},
		{
			"label": "missing_topic_should_drop",
			"topic": "",
			"gain_loss": 0.1,
			"salience": 0.2,
			"scope": "household",
			"owner_id": "",
			"tags": [],
			"summary": "",
		},
	])
	if sanitized.size() != 1:
		push_error("Expected one valid sanitized driver row")
		return false
	var row_variant = sanitized[0]
	if not (row_variant is Dictionary):
		push_error("Expected sanitized row to be dictionary")
		return false
	var row: Dictionary = row_variant
	var expected_keys = ["label", "topic", "gain_loss", "salience", "scope", "owner_id", "tags", "summary"]
	for key in expected_keys:
		if not row.has(key):
			push_error("Sanitized row missing key: %s" % key)
			return false
	if float(row.get("gain_loss", 0.0)) != 1.0:
		push_error("Expected gain_loss clamp to 1.0")
		return false
	if float(row.get("salience", 1.0)) != 0.0:
		push_error("Expected salience clamp to 0.0")
		return false
	if String(row.get("scope", "")) != "household":
		push_error("Expected household scope to pass through")
		return false
	var tags_variant = row.get("tags", [])
	if not (tags_variant is Array):
		push_error("Expected tags array in sanitized row")
		return false
	var tags: Array = tags_variant
	if tags.size() != 2 or not tags.has("food") or not tags.has("belonging"):
		push_error("Expected deduplicated non-empty tags")
		return false

	print("Cultural driver JSON contract test passed")
	return true
