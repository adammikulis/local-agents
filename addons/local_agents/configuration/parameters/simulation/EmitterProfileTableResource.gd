extends Resource
class_name LocalAgentsEmitterProfileTableResource

const REQUIRED_PRESET_FIELDS: Array[String] = [
	"preset_id",
	"enabled",
	"radiant_heat",
	"temperature_k",
]

const _CANONICAL_PRESETS: Array[Dictionary] = [
	{
		"preset_id": "baseline_radiant_primary",
		"enabled": true,
		"radiant_heat": 1.0,
		"temperature_k": 5772.0,
	},
	{
		"preset_id": "baseline_radiant_secondary",
		"enabled": true,
		"radiant_heat": 0.35,
		"temperature_k": 700.0,
	},
	{
		"preset_id": "baseline_radiant_high_flux",
		"enabled": true,
		"radiant_heat": 0.8,
		"temperature_k": 1400.0,
	},
]

@export var schema_version: int = 1
@export var preset_table_key: String = "generic_emitters_v2"
@export var profile_table_key: String = "canonical_emitters_v1"
@export var radiant_heat_enabled: bool = true
@export var emitters_enabled: bool = true
@export var presets: Array[Dictionary] = []
@export var sources: Array[Dictionary] = []

func ensure_defaults() -> void:
	if presets.is_empty() and sources.is_empty():
		presets = _CANONICAL_PRESETS.duplicate(true)
	elif presets.is_empty() and not sources.is_empty():
		presets = sources.duplicate(true)
	var normalized: Array[Dictionary] = []
	for preset_variant in presets:
		if not (preset_variant is Dictionary):
			continue
		var preset = preset_variant as Dictionary
		var preset_id := String(preset.get("preset_id", preset.get("source_id", ""))).strip_edges().to_lower()
		if preset_id == "":
			continue
		normalized.append({
			"preset_id": preset_id,
			"source_id": preset_id,
			"enabled": bool(preset.get("enabled", true)),
			"radiant_heat": float(preset.get("radiant_heat", 0.0)),
			"temperature_k": float(preset.get("temperature_k", 0.0)),
		})
	if normalized.is_empty():
		normalized = _CANONICAL_PRESETS.duplicate(true)
		for i in range(normalized.size()):
			var row = normalized[i]
			if row is Dictionary:
				(row as Dictionary)["source_id"] = String((row as Dictionary).get("preset_id", ""))
	presets = normalized
	sources = normalized.duplicate(true)
	var normalized_key = preset_table_key.strip_edges()
	preset_table_key = "generic_emitters_v2" if normalized_key == "" else normalized_key
	profile_table_key = preset_table_key

func default_contract_dict() -> Dictionary:
	ensure_defaults()
	return {
		"schema_version": schema_version,
		"preset_table_key": preset_table_key,
		"profile_table_key": preset_table_key,
		"enabled": emitters_enabled,
		"radiant_heat_enabled": radiant_heat_enabled,
		"presets": presets.duplicate(true),
		"sources": sources.duplicate(true),
	}

func validate_emitters_contract(contract: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	if not contract.has("schema_version"):
		errors.append("missing_schema_version")
	if not contract.has("preset_table_key") and not contract.has("profile_table_key"):
		errors.append("missing_preset_table_key")
	if not contract.has("enabled"):
		errors.append("missing_enabled")
	if not contract.has("radiant_heat_enabled"):
		errors.append("missing_radiant_heat_enabled")
	var presets_variant = contract.get("presets", contract.get("sources", null))
	if not (presets_variant is Array):
		errors.append("invalid_presets_type")
	else:
		for preset_variant in presets_variant:
			if not (preset_variant is Dictionary):
				errors.append("invalid_preset_row_type")
				continue
			var preset = preset_variant as Dictionary
			if not preset.has("preset_id") and not preset.has("source_id"):
				errors.append("missing_preset_field_preset_id")
			for key in REQUIRED_PRESET_FIELDS:
				if key == "preset_id":
					continue
				if not preset.has(key):
					errors.append("missing_preset_field_%s" % key)
	return {"ok": errors.is_empty(), "errors": errors}
