extends RefCounted
class_name LocalAgentsDeterministicRNG

var _base_seed: int = 1

func set_base_seed(seed: int) -> void:
    _base_seed = _sanitize_seed(seed)

func set_base_seed_from_text(seed_text: String) -> void:
    _base_seed = _hash_to_seed(seed_text)

func get_base_seed() -> int:
    return _base_seed

func seed_for_tick(tick: int, subsystem: String = "") -> int:
    return derive_seed(subsystem, "", "", tick)

func derive_seed(subsystem: String, entity_id: String, stage: String, tick: int) -> int:
    var payload = "%d|%s|%s|%s|%d" % [_base_seed, subsystem, entity_id, stage, tick]
    return _hash_to_seed(payload)

func make_rng(subsystem: String, entity_id: String, stage: String, tick: int) -> RandomNumberGenerator:
    var rng = RandomNumberGenerator.new()
    rng.seed = derive_seed(subsystem, entity_id, stage, tick)
    return rng

func randomf(subsystem: String, entity_id: String, stage: String, tick: int) -> float:
    return make_rng(subsystem, entity_id, stage, tick).randf()

func randi_range(subsystem: String, entity_id: String, stage: String, tick: int, min_value: int, max_value: int) -> int:
    return make_rng(subsystem, entity_id, stage, tick).randi_range(min_value, max_value)

func _sanitize_seed(seed: int) -> int:
    var value = seed
    if value == 0:
        value = 1
    if value < 0:
        value = -value
    return value

func _hash_to_seed(text: String) -> int:
    var hash_value: int = 1469598103934665603
    var prime: int = 1099511628211
    var bytes = text.to_utf8_buffer()
    for byte_value in bytes:
        hash_value = hash_value ^ int(byte_value)
        hash_value = int(hash_value * prime)
    return _sanitize_seed(hash_value)
