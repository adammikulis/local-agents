extends Resource
class_name LocalAgentsInferenceParams

@export var inference_config_name: String = ""
@export var temperature: float = 0.8
@export var max_tokens: int = 256
@export var top_p: float = 1.0
@export var top_k: int = 0
@export var min_p: float = 0.0
@export var typical_p: float = 1.0
@export var repeat_penalty: float = 1.1
@export var repeat_last_n: int = 64
@export var frequency_penalty: float = 0.0
@export var presence_penalty: float = 0.0
@export var seed: int = -1
@export var mirostat_mode: int = 0
@export var mirostat_tau: float = 5.0
@export var mirostat_eta: float = 0.1
@export var mirostat_m: int = 100
@export var backend: String = ""
@export var output_json: bool = false
@export var extra_options: Dictionary = {}

func to_options() -> Dictionary:
    var opts: Dictionary = {
        "temperature": temperature,
        "max_tokens": max_tokens,
        "top_p": top_p,
        "top_k": top_k,
        "min_p": min_p,
        "typical_p": typical_p,
        "repeat_penalty": repeat_penalty,
        "repeat_last_n": repeat_last_n,
        "frequency_penalty": frequency_penalty,
        "presence_penalty": presence_penalty,
        "mirostat": mirostat_mode,
        "mirostat_tau": mirostat_tau,
        "mirostat_eta": mirostat_eta,
        "mirostat_m": mirostat_m,
        "output_json": output_json,
    }
    if backend.strip_edges() != "":
        opts["backend"] = backend.strip_edges()
    if seed >= 0:
        opts["seed"] = seed
    for key in extra_options.keys():
        opts[key] = extra_options[key]
    return opts
