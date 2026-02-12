extends RefCounted
class_name LocalAgentsSimulationStateHasher

func hash_state(state: Dictionary) -> String:
    var canonical = _canonicalize(state)
    var raw = JSON.stringify(canonical, "", false, true)
    var hasher = HashingContext.new()
    var err = hasher.start(HashingContext.HASH_SHA256)
    if err != OK:
        return ""
    hasher.update(raw.to_utf8_buffer())
    return hasher.finish().hex_encode()

func _canonicalize(value: Variant) -> Variant:
    match typeof(value):
        TYPE_DICTIONARY:
            var input: Dictionary = value
            var keys = input.keys()
            keys.sort_custom(func(a, b): return String(a) < String(b))
            var output = {}
            for key in keys:
                output[key] = _canonicalize(input[key])
            return output
        TYPE_ARRAY:
            var array_value: Array = value
            var output_array: Array = []
            output_array.resize(array_value.size())
            for idx in array_value.size():
                output_array[idx] = _canonicalize(array_value[idx])
            return output_array
        TYPE_FLOAT:
            var scaled = round(value * 1000000.0)
            return float(scaled) / 1000000.0
        _:
            return value
