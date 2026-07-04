extends CharacterBody3D
class_name AnimalActor

# Base for the ANIMAL kingdom (living_creature/animal/...). Animals move, sense, eat,
# and breed — all unified here so mammals, birds, reptiles, etc. share one contract and
# only specialize chemistry, taxonomy, and species behavior. Plants and fungi are
# separate sessile kingdoms (PlantActor / FungusActor) that don't inherit this.
#
# Locomotion:
#   - NavigationAgent3D pathfinding produces the desired heading.
#   - Grounded animals fall with gravity and rest on the floor collider, so terrain
#     height, small steps, and hopping onto ledges come "for free" from CharacterBody3D.
#   - Flying animals (birds) move in full 3D toward a cruise altitude instead.
#   - Flock/boids output, when present, overrides steering for that step.
# Taxonomy is expressed as category/subtype -> `animal/<category>/<subtype>`.

const TaxonomyScript = preload("res://addons/local_agents/simulation/LivingEntityTaxonomy.gd")
const SmellEmissionProfileScript = preload("res://addons/local_agents/configuration/parameters/simulation/SmellEmissionProfileResource.gd")
const ChemicalProfileScript = preload("res://addons/local_agents/configuration/parameters/simulation/MammalProfileResource.gd")
const LivingProfileScript = preload("res://addons/local_agents/configuration/parameters/simulation/LivingEntityProfileResource.gd")

# Every animal emits a chemical scent into the shared smell field, senses food/danger
# scents, has a diet, and can breed. Subclasses specialize chemistry/taxonomy/behavior.
@export var smell_kind: String = ""
@export var smell_strength: float = 0.35
@export var emission_profile: Resource

# Smell sensing (food attraction + danger flee)
@export var can_smell_enabled: bool = true
@export var food_smell_radius_cells: int = 7
@export var danger_smell_radius_cells: int = 4
@export var smell_acuity: float = 1.0
@export var diet: String = "herbivore"  # herbivore | carnivore | omnivore
@export var profile_food: Resource
@export var profile_danger: Resource
@export var living_profile: Resource

# Reproduction
@export var can_breed: bool = true
@export var maturity_seconds: float = 12.0
@export var breed_cooldown_seconds: float = 22.0

@export var move_speed: float = 1.0
@export var flee_speed: float = 2.5
@export var gravity: float = 12.0
@export var jump_speed: float = 4.0
@export var can_fly: bool = false
@export var cruise_altitude: float = 6.0
@export var flee_escape_distance: float = 4.0
@export var decision_commit_seconds: float = 1.4

var _age_seconds: float = 0.0
var _breed_cooldown_remaining: float = 0.0

var _nav_agent: NavigationAgent3D = null
var _food_target: Vector3 = Vector3.ZERO
var _has_food_target: bool = false
var _flee_direction: Vector3 = Vector3.ZERO
var _flee_target: Vector3 = Vector3.ZERO
var _flee_remaining: float = 0.0
var _decision_hold_remaining: float = 0.0
var _jump_cooldown_remaining: float = 0.0
var _pending_behavior_velocity: Vector3 = Vector3.ZERO
var _pending_behavior_speed: float = 0.0
var _pending_behavior_intent: Vector3 = Vector3.ZERO
var _flock_output_ttl: float = 0.0

func _ready() -> void:
	add_to_group("living_creature")
	add_to_group("living_animal")
	add_to_group("animal_actor")
	add_to_group("living_smell_source")
	add_to_group("field_selectable")
	_register_creature_groups()
	_nav_agent = get_node_or_null("NavigationAgent3D")
	_setup_emission()
	_setup_profiles()
	_init_creature()

# --- smell emission ---------------------------------------------------------

func _setup_emission() -> void:
	if smell_kind.strip_edges() == "":
		smell_kind = _default_smell_kind()
	if emission_profile == null:
		emission_profile = SmellEmissionProfileScript.new()
		emission_profile.set("base_strength", smell_strength)
		emission_profile.set("chemicals", _default_emission_chemicals())

func get_smell_source_payload() -> Dictionary:
	if emission_profile == null:
		return {}
	return emission_profile.call("to_payload", global_position, _smell_id(), smell_kind)

func _default_smell_kind() -> String:
	return "animal"

func _default_emission_chemicals() -> Dictionary:
	return {}

func _smell_id() -> String:
	return "%s_%d" % [smell_kind, get_instance_id()]

# --- smell sensing (food attraction + danger flee) --------------------------

func _setup_profiles() -> void:
	if profile_food == null:
		profile_food = ChemicalProfileScript.new()
	if profile_danger == null:
		profile_danger = ChemicalProfileScript.new()
	if living_profile == null:
		living_profile = LivingProfileScript.new()
	_configure_living_profile()
	_init_default_profiles()

func can_smell() -> bool:
	return can_smell_enabled

func get_food_smell_radius_cells() -> int:
	return maxi(1, food_smell_radius_cells)

func get_danger_smell_radius_cells() -> int:
	return maxi(1, danger_smell_radius_cells)

func get_food_chemical_weights() -> Dictionary:
	return profile_food.call("as_weights", true, true)

func get_danger_chemical_weights() -> Dictionary:
	return profile_danger.call("as_weights", false, false)

func get_danger_threshold() -> float:
	return float(profile_danger.get("danger_threshold"))

# Species chemistry / profile hooks (override in subclasses).
func _init_default_profiles() -> void:
	pass

func _configure_living_profile() -> void:
	pass

# --- reproduction -----------------------------------------------------------

func is_adult() -> bool:
	return _age_seconds >= maturity_seconds

func can_reproduce() -> bool:
	return can_breed and is_adult() and _breed_cooldown_remaining <= 0.0 and not is_fleeing()

func mark_bred() -> void:
	_breed_cooldown_remaining = breed_cooldown_seconds

func set_age_seconds(seconds: float) -> void:
	_age_seconds = maxf(0.0, seconds)

# --- overridable hooks ------------------------------------------------------

func _register_creature_groups() -> void:
	pass

func _init_creature() -> void:
	pass

func taxonomy_category() -> String:
	return "animal"

func taxonomy_subtype() -> String:
	return ""

func taxonomy_path() -> Array:
	return TaxonomyScript.animal_path(taxonomy_category(), taxonomy_subtype())

# --- per-tick locomotion ----------------------------------------------------

# Locomotion runs EVERY physics frame so gravity/move_and_slide never teleport a body
# through thin voxel-terrain collision. Behavior decisions (food/flee/flock) are set by
# controllers at their own cadence; simulation_step is kept only for API compatibility.
func simulation_step(_delta: float) -> void:
	pass

func _physics_process(delta: float) -> void:
	_age_seconds += delta
	if _breed_cooldown_remaining > 0.0:
		_breed_cooldown_remaining = maxf(0.0, _breed_cooldown_remaining - delta)
	if _decision_hold_remaining > 0.0:
		_decision_hold_remaining = maxf(0.0, _decision_hold_remaining - delta)
	if _jump_cooldown_remaining > 0.0:
		_jump_cooldown_remaining = maxf(0.0, _jump_cooldown_remaining - delta)
	if _flock_output_ttl > 0.0:
		_flock_output_ttl = maxf(0.0, _flock_output_ttl - delta)
	var heading := _resolve_heading(delta)
	if can_fly:
		_drive_flight(heading, delta)
	else:
		_drive_ground(heading, delta)

func _resolve_heading(delta: float) -> Vector3:
	# Flock/boids output takes priority while fresh (persists between controller updates).
	if _flock_output_ttl > 0.0 and _pending_behavior_velocity.length_squared() > 0.0001 and _pending_behavior_speed > 0.0:
		return _pending_behavior_velocity.normalized() * _pending_behavior_speed
	if _flee_remaining > 0.0:
		_flee_remaining = maxf(0.0, _flee_remaining - delta)
		return _heading_to(_flee_target, flee_speed, _flee_direction)
	if _has_food_target:
		var flat := Vector3(_food_target.x, global_position.y, _food_target.z)
		if flat.distance_to(global_position) <= 0.06:
			_has_food_target = false
			return Vector3.ZERO
		return _heading_to(flat, move_speed)
	return Vector3.ZERO

# Prefer NavigationAgent3D pathing; fall back to a straight line when the nav map is
# not yet synced or the agent is missing.
func _heading_to(target: Vector3, speed: float, fallback_dir: Vector3 = Vector3.ZERO) -> Vector3:
	if _nav_agent != null:
		_nav_agent.target_position = target
		if not _nav_agent.is_navigation_finished():
			var next := _nav_agent.get_next_path_position()
			var d := next - global_position
			if not can_fly:
				d.y = 0.0
			if d.length_squared() > 0.000001:
				return d.normalized() * speed
			return Vector3.ZERO
	var dir := target - global_position
	if not can_fly:
		dir.y = 0.0
	if dir.length_squared() > 0.0025:
		return dir.normalized() * speed
	if fallback_dir.length_squared() > 0.0001:
		var flat := fallback_dir
		if not can_fly:
			flat.y = 0.0
		if flat.length_squared() > 0.0001:
			return flat.normalized() * speed
	return Vector3.ZERO

func _drive_ground(heading: Vector3, delta: float) -> void:
	velocity.x = heading.x
	velocity.z = heading.z
	if is_on_floor():
		if velocity.y < 0.0:
			velocity.y = 0.0
	else:
		velocity.y -= gravity * delta
	move_and_slide()

func _drive_flight(heading: Vector3, delta: float) -> void:
	velocity.x = heading.x
	velocity.z = heading.z
	if absf(heading.y) > 0.0001:
		velocity.y = heading.y
	else:
		var altitude_error := cruise_altitude - global_position.y
		velocity.y = clampf(altitude_error, -move_speed, move_speed)
	move_and_slide()

# --- jumping ----------------------------------------------------------------

func jump(strength_scale: float = 1.0) -> void:
	if can_fly:
		return
	if not is_on_floor() or _jump_cooldown_remaining > 0.0:
		return
	velocity.y = jump_speed * maxf(0.1, strength_scale)
	_jump_cooldown_remaining = 0.35

func is_grounded() -> bool:
	return is_on_floor()

# --- behavior/targeting API -------------------------------------------------

# Flock/boids controllers push a desired velocity here; consumed next step.
func apply_flock_output(next_velocity: Vector3, next_speed: float, next_intent: Vector3 = Vector3.ZERO) -> void:
	_pending_behavior_velocity = next_velocity
	_pending_behavior_speed = maxf(0.0, float(next_speed))
	_pending_behavior_intent = next_intent
	_flock_output_ttl = 0.5

# Back-compat alias (older boids/mammal controllers call this name).
func apply_mammal_behavior_output(next_velocity: Vector3, next_speed: float, next_intent: Vector3 = Vector3.ZERO) -> void:
	apply_flock_output(next_velocity, next_speed, next_intent)

func set_food_target(position: Vector3) -> void:
	if _decision_hold_remaining > 0.0 and _has_food_target:
		return
	_food_target = position
	_has_food_target = true
	_decision_hold_remaining = decision_commit_seconds

func clear_food_target() -> void:
	if _decision_hold_remaining > 0.0 and _has_food_target:
		return
	_has_food_target = false

func trigger_flee(away_from: Vector3, duration_seconds: float) -> void:
	var direction := global_position - away_from
	direction.y = 0.0
	if direction.length_squared() <= 0.0001:
		direction = Vector3(1.0, 0.0, 0.0)
	_flee_direction = direction.normalized()
	_flee_target = global_position + _flee_direction * flee_escape_distance
	var was_calm := _flee_remaining <= 0.0
	_flee_remaining = maxf(_flee_remaining, duration_seconds)
	_decision_hold_remaining = decision_commit_seconds
	# Startle hop the first time a threat appears (e.g. leaping to evade a snake).
	if was_calm:
		jump()

func is_fleeing() -> bool:
	return _flee_remaining > 0.0
