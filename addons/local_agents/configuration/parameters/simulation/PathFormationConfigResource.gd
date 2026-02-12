extends Resource
class_name LocalAgentsPathFormationConfigResource

@export var schema_version: int = 1
@export var heat_decay_per_tick: float = 0.015
@export var strength_decay_per_tick: float = 0.004
@export var heat_gain_per_weight: float = 0.065
@export var strength_gain_factor: float = 0.075
@export var max_heat: float = 8.0
@export var max_strength: float = 1.0

func to_dict() -> Dictionary:
    return {
        "schema_version": schema_version,
        "heat_decay_per_tick": heat_decay_per_tick,
        "strength_decay_per_tick": strength_decay_per_tick,
        "heat_gain_per_weight": heat_gain_per_weight,
        "strength_gain_factor": strength_gain_factor,
        "max_heat": max_heat,
        "max_strength": max_strength,
    }

func from_dict(values: Dictionary) -> void:
    schema_version = int(values.get("schema_version", schema_version))
    heat_decay_per_tick = clampf(float(values.get("heat_decay_per_tick", heat_decay_per_tick)), 0.0, 1.0)
    strength_decay_per_tick = clampf(float(values.get("strength_decay_per_tick", strength_decay_per_tick)), 0.0, 1.0)
    heat_gain_per_weight = clampf(float(values.get("heat_gain_per_weight", heat_gain_per_weight)), 0.0, 4.0)
    strength_gain_factor = clampf(float(values.get("strength_gain_factor", strength_gain_factor)), 0.0, 2.0)
    max_heat = maxf(0.1, float(values.get("max_heat", max_heat)))
    max_strength = maxf(0.05, float(values.get("max_strength", max_strength)))
