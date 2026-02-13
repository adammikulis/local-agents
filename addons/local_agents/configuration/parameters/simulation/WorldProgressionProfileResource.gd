extends Resource
class_name LocalAgentsWorldProgressionProfileResource

@export var schema_version: int = 1
@export var start_year: float = -10000.0
@export var end_year: float = 2500.0
@export var temperature_shift_curve: Curve
@export var moisture_shift_curve: Curve
@export var food_density_multiplier_curve: Curve
@export var wood_density_multiplier_curve: Curve
@export var stone_density_multiplier_curve: Curve

func _init() -> void:
	_ensure_defaults()

func sample_year(year: float) -> Dictionary:
	_ensure_defaults()
	var span = maxf(1.0, end_year - start_year)
	var t = clampf((year - start_year) / span, 0.0, 1.0)
	return {
		"year": year,
		"t": t,
		"temperature_shift": _sample_curve(temperature_shift_curve, t, 0.0),
		"moisture_shift": _sample_curve(moisture_shift_curve, t, 0.0),
		"food_density_multiplier": _sample_curve(food_density_multiplier_curve, t, 1.0),
		"wood_density_multiplier": _sample_curve(wood_density_multiplier_curve, t, 1.0),
		"stone_density_multiplier": _sample_curve(stone_density_multiplier_curve, t, 1.0),
	}

func apply_to_worldgen_config(config: Resource, year: float) -> void:
	if config == null:
		return
	var sampled = sample_year(year)
	config.set("simulated_year", year)
	config.set("progression_profile_id", "year_%d" % int(round(year)))
	config.set("progression_temperature_shift", sampled.get("temperature_shift", 0.0))
	config.set("progression_moisture_shift", sampled.get("moisture_shift", 0.0))
	config.set("progression_food_density_multiplier", sampled.get("food_density_multiplier", 1.0))
	config.set("progression_wood_density_multiplier", sampled.get("wood_density_multiplier", 1.0))
	config.set("progression_stone_density_multiplier", sampled.get("stone_density_multiplier", 1.0))

func _ensure_defaults() -> void:
	if temperature_shift_curve == null:
		temperature_shift_curve = _build_curve([
			Vector2(0.0, -0.08),
			Vector2(0.35, -0.02),
			Vector2(0.7, 0.06),
			Vector2(1.0, 0.12),
		])
	if moisture_shift_curve == null:
		moisture_shift_curve = _build_curve([
			Vector2(0.0, 0.03),
			Vector2(0.35, 0.0),
			Vector2(0.7, -0.04),
			Vector2(1.0, -0.08),
		])
	if food_density_multiplier_curve == null:
		food_density_multiplier_curve = _build_curve([
			Vector2(0.0, 1.15),
			Vector2(0.35, 1.05),
			Vector2(0.7, 0.95),
			Vector2(1.0, 0.82),
		])
	if wood_density_multiplier_curve == null:
		wood_density_multiplier_curve = _build_curve([
			Vector2(0.0, 1.25),
			Vector2(0.35, 1.0),
			Vector2(0.7, 0.88),
			Vector2(1.0, 0.76),
		])
	if stone_density_multiplier_curve == null:
		stone_density_multiplier_curve = _build_curve([
			Vector2(0.0, 0.82),
			Vector2(0.35, 0.9),
			Vector2(0.7, 1.0),
			Vector2(1.0, 1.14),
		])

func _build_curve(points: Array) -> Curve:
	var c := Curve.new()
	for point_variant in points:
		if point_variant is Vector2:
			c.add_point(point_variant as Vector2)
	return c

func _sample_curve(curve: Curve, t: float, default_value: float) -> float:
	if curve == null:
		return default_value
	return float(curve.sample_baked(clampf(t, 0.0, 1.0)))
