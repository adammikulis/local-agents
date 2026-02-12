extends Resource
class_name LocalAgentsLlmRequestProfileResource

@export var schema_version: int = 1
@export var profile_id: String = "default"
@export var temperature: float = 0.4
@export var top_p: float = 0.9
@export var max_tokens: int = 128
@export var stop: PackedStringArray = PackedStringArray()
@export var reset_context: bool = true
@export var cache_prompt: bool = false
@export var retry_count: int = 1
@export var retry_seed_step: int = 1
@export var output_json: bool = false

func to_dict() -> Dictionary:
	return {
		"schema_version": schema_version,
		"profile_id": profile_id,
		"temperature": temperature,
		"top_p": top_p,
		"max_tokens": max_tokens,
		"stop": stop.duplicate(),
		"reset_context": reset_context,
		"cache_prompt": cache_prompt,
		"retry_count": retry_count,
		"retry_seed_step": retry_seed_step,
		"output_json": output_json,
	}

func from_dict(payload: Dictionary) -> void:
	schema_version = int(payload.get("schema_version", schema_version))
	profile_id = String(payload.get("profile_id", profile_id)).strip_edges()
	temperature = clampf(float(payload.get("temperature", temperature)), 0.0, 2.0)
	top_p = clampf(float(payload.get("top_p", top_p)), 0.0, 1.0)
	max_tokens = maxi(1, int(payload.get("max_tokens", max_tokens)))
	stop = PackedStringArray(payload.get("stop", stop))
	reset_context = bool(payload.get("reset_context", reset_context))
	cache_prompt = bool(payload.get("cache_prompt", cache_prompt))
	retry_count = maxi(0, int(payload.get("retry_count", retry_count)))
	retry_seed_step = maxi(1, int(payload.get("retry_seed_step", retry_seed_step)))
	output_json = bool(payload.get("output_json", output_json))

func to_runtime_options(seed: int) -> Dictionary:
	var options: Dictionary = {
		"seed": seed,
		"temperature": temperature,
		"top_p": top_p,
		"max_tokens": max_tokens,
		"stop": stop.duplicate(),
		"reset_context": reset_context,
		"cache_prompt": cache_prompt,
		"output_json": output_json,
	}
	return options
