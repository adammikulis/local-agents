extends Resource
class_name LocalAgentsMaterialProfileTableResource

const REQUIRED_PROFILE_FIELDS: Array[String] = [
	"density",
	"heat_capacity",
	"thermal_conductivity",
	"cohesion",
	"hardness",
	"porosity",
	"freeze_temp_k",
	"melt_temp_k",
	"thermal_expansion",
	"brittle_threshold",
	"fracture_toughness",
	"moisture_capacity",
]

const _BUILTIN_PROFILE_KEYS: Array[String] = [
	"rock",
	"soil",
	"water",
	"ice",
	"metal",
	"wood",
	"unknown",
]

const _CANONICAL_BUILTIN_PROFILES := {
	"rock": {
		"density": 2600.0,
		"heat_capacity": 790.0,
		"thermal_conductivity": 2.5,
		"cohesion": 0.85,
		"hardness": 0.82,
		"porosity": 0.08,
		"freeze_temp_k": 260.0,
		"melt_temp_k": 1470.0,
		"thermal_expansion": 8.0e-6,
		"brittle_threshold": 0.78,
		"fracture_toughness": 1.8,
		"moisture_capacity": 0.06,
	},
	"soil": {
		"density": 1450.0,
		"heat_capacity": 1480.0,
		"thermal_conductivity": 0.85,
		"cohesion": 0.42,
		"hardness": 0.34,
		"porosity": 0.42,
		"freeze_temp_k": 272.0,
		"melt_temp_k": 1700.0,
		"thermal_expansion": 2.2e-5,
		"brittle_threshold": 0.44,
		"fracture_toughness": 0.5,
		"moisture_capacity": 0.34,
	},
	"water": {
		"density": 1000.0,
		"heat_capacity": 4186.0,
		"thermal_conductivity": 0.58,
		"cohesion": 0.02,
		"hardness": 0.0,
		"porosity": 0.0,
		"freeze_temp_k": 273.15,
		"melt_temp_k": 273.15,
		"thermal_expansion": 2.1e-4,
		"brittle_threshold": 0.0,
		"fracture_toughness": 0.01,
		"moisture_capacity": 1.0,
	},
	"ice": {
		"density": 917.0,
		"heat_capacity": 2100.0,
		"thermal_conductivity": 2.2,
		"cohesion": 0.2,
		"hardness": 0.18,
		"porosity": 0.03,
		"freeze_temp_k": 273.15,
		"melt_temp_k": 273.15,
		"thermal_expansion": 5.1e-5,
		"brittle_threshold": 0.86,
		"fracture_toughness": 0.14,
		"moisture_capacity": 0.08,
	},
	"metal": {
		"density": 7800.0,
		"heat_capacity": 490.0,
		"thermal_conductivity": 50.0,
		"cohesion": 0.95,
		"hardness": 0.92,
		"porosity": 0.01,
		"freeze_temp_k": 1728.0,
		"melt_temp_k": 1811.0,
		"thermal_expansion": 1.2e-5,
		"brittle_threshold": 0.32,
		"fracture_toughness": 65.0,
		"moisture_capacity": 0.0,
	},
	"wood": {
		"density": 700.0,
		"heat_capacity": 1700.0,
		"thermal_conductivity": 0.16,
		"cohesion": 0.58,
		"hardness": 0.46,
		"porosity": 0.55,
		"freeze_temp_k": 260.0,
		"melt_temp_k": 873.0,
		"thermal_expansion": 3.4e-5,
		"brittle_threshold": 0.52,
		"fracture_toughness": 3.2,
		"moisture_capacity": 0.62,
	},
	"unknown": {
		"density": 1200.0,
		"heat_capacity": 1000.0,
		"thermal_conductivity": 1.0,
		"cohesion": 0.5,
		"hardness": 0.5,
		"porosity": 0.25,
		"freeze_temp_k": 273.15,
		"melt_temp_k": 1200.0,
		"thermal_expansion": 1.0e-5,
		"brittle_threshold": 0.5,
		"fracture_toughness": 1.0,
		"moisture_capacity": 0.25,
	},
}

@export var schema_version: int = 1
@export var profile_table_key: String = "canonical_material_profiles_v1"
@export var profiles: Dictionary = {}

func ensure_defaults() -> void:
	var updated_profiles: Dictionary = {}
	for profile_key in _BUILTIN_PROFILE_KEYS:
		var resolved := _profile_with_required_fields(profile_key)
		updated_profiles[profile_key] = resolved
	profiles = updated_profiles

func to_dict() -> Dictionary:
	ensure_defaults()
	return {
		"schema_version": schema_version,
		"profile_table_key": profile_table_key,
		"profiles": profiles.duplicate(true),
	}

func resolve_profile(material_id: String) -> Dictionary:
	ensure_defaults()
	var profile_key := canonical_profile_key(material_id)
	var resolved_variant = profiles.get(profile_key, profiles.get("unknown", {}))
	var resolved: Dictionary = {}
	if resolved_variant is Dictionary:
		resolved = (resolved_variant as Dictionary).duplicate(true)
	resolved["profile_key"] = profile_key
	return resolved

func canonical_profile_key(material_id: String) -> String:
	var normalized = material_id.strip_edges().to_lower()
	if normalized.begins_with("material:"):
		normalized = normalized.substr(9)
	match normalized:
		"rock", "stone", "gravel":
			return "rock"
		"soil", "dirt", "sand", "clay", "silt":
			return "soil"
		"water", "liquid_water":
			return "water"
		"ice", "frozen_water":
			return "ice"
		"metal", "steel", "iron", "alloy":
			return "metal"
		"wood", "timber":
			return "wood"
		"unknown", "":
			return "unknown"
		_:
			return "unknown"

func validate_profile(profile: Dictionary) -> Dictionary:
	var missing_fields: Array[String] = []
	for key in REQUIRED_PROFILE_FIELDS:
		if not profile.has(key):
			missing_fields.append(key)
	return {
		"ok": missing_fields.is_empty(),
		"missing_fields": missing_fields,
	}

func _profile_with_required_fields(profile_key: String) -> Dictionary:
	var source_variant = _CANONICAL_BUILTIN_PROFILES.get(profile_key, _CANONICAL_BUILTIN_PROFILES["unknown"])
	var source: Dictionary = {}
	if source_variant is Dictionary:
		source = (source_variant as Dictionary).duplicate(true)
	var normalized: Dictionary = {}
	for key in REQUIRED_PROFILE_FIELDS:
		normalized[key] = float(source.get(key, 0.0))
	return normalized
