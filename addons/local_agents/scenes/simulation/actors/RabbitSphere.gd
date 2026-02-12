extends Node3D
class_name RabbitSphere

signal seed_dropped(rabbit_id: String, count: int)

@export var rabbit_id: String = ""
@export var forage_speed: float = 0.65
@export var flee_speed: float = 2.6
@export var smell_kind: String = "rabbit"
@export var smell_strength: float = 0.35
@export var digestion_seconds: float = 18.0

var _food_target: Vector3 = Vector3.ZERO
var _has_food_target: bool = false
var _flee_direction: Vector3 = Vector3.ZERO
var _flee_remaining: float = 0.0
var _digestion_queue: Array[Dictionary] = []

func _ready() -> void:
	add_to_group("living_smell_source")

func simulation_step(delta: float) -> void:
	_update_digestion(delta)
	if _flee_remaining > 0.0:
		_flee_remaining = maxf(0.0, _flee_remaining - delta)
		if _flee_direction.length_squared() > 0.0001:
			global_position += _flee_direction * flee_speed * delta
		return
	if _has_food_target:
		_move_toward_food(delta)

func set_food_target(position: Vector3) -> void:
	_food_target = position
	_has_food_target = true

func clear_food_target() -> void:
	_has_food_target = false

func trigger_flee(away_from: Vector3, duration_seconds: float) -> void:
	var direction := global_position - away_from
	if direction.length_squared() <= 0.0001:
		direction = Vector3(1.0, 0.0, 0.0)
	_flee_direction = direction.normalized()
	_flee_remaining = maxf(_flee_remaining, duration_seconds)

func is_fleeing() -> bool:
	return _flee_remaining > 0.0

func ingest_seeds(seed_count: int) -> void:
	if seed_count <= 0:
		return
	_digestion_queue.append({
		"remaining": digestion_seconds,
		"count": seed_count,
	})

func get_smell_source_payload() -> Dictionary:
	return {
		"id": _id(),
		"position": global_position,
		"strength": smell_strength,
		"kind": smell_kind,
	}

func _move_toward_food(delta: float) -> void:
	var direction := _food_target - global_position
	direction.y = 0.0
	var distance := direction.length()
	if distance <= 0.05:
		_has_food_target = false
		return
	global_position += direction.normalized() * forage_speed * delta

func _update_digestion(delta: float) -> void:
	if _digestion_queue.is_empty():
		return
	for i in range(_digestion_queue.size() - 1, -1, -1):
		var entry = _digestion_queue[i]
		entry["remaining"] = float(entry.get("remaining", 0.0)) - delta
		if float(entry["remaining"]) <= 0.0:
			emit_signal("seed_dropped", _id(), int(entry.get("count", 0)))
			_digestion_queue.remove_at(i)
		else:
			_digestion_queue[i] = entry

func _id() -> String:
	if rabbit_id.strip_edges() != "":
		return rabbit_id
	return "rabbit_%d" % get_instance_id()
