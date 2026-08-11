extends Resource
class_name LocalAgentInferenceParams

## How the model should *generate*: sampling, penalties, and which backend runs the request.
##
## This is the companion to LocalAgentModelProfile: the profile says which weights to load, this
## says how to sample from them. Save it as a `.tres`, tweak it in the inspector, and hand it to
## LocalAgent.configure() (or drop it in a LAConfigList).
##
## Defaults are deliberately safe and general-purpose. The two knobs worth touching first are
## Temperature (creativity) and Max tokens (reply length).

## Human-readable label for this preset, shown wherever presets are listed. Purely cosmetic.
@export_placeholder("<default>") var inference_config_name: String = ""

@export_group("Sampling")

## Creativity. Low values (0.2) make the model repetitive but focused. High values (1.2+) make it
## inventive but prone to nonsense. 0 makes it fully deterministic.
@export_range(0.0, 2.0, 0.01) var temperature: float = 0.8

## Hard ceiling on the length of one reply. The model may stop earlier on its own.
@export_range(1, 8192, 1, "or_greater", "suffix:tok") var max_tokens: int = 256

## Nucleus sampling: only consider the most likely words that together add up to this probability.
## 1.0 disables it. Lower (0.9) trims the long tail of unlikely words.
@export_range(0.0, 1.0, 0.01) var top_p: float = 1.0

## Only consider the N most likely next words. 0 disables it. 40 is a common choice.
@export_range(0, 200, 1) var top_k: int = 0

## Drop any word less likely than this fraction of the best word's probability. 0 disables it.
@export_range(0.0, 1.0, 0.01) var min_p: float = 0.0

## Locally-typical sampling: prefers words of "average" surprise. 1.0 disables it.
@export_range(0.0, 1.0, 0.01) var typical_p: float = 1.0

## Random seed. -1 draws a fresh seed for every generation, so the reply differs each time. Pin it
## to any value to make a run reproducible.
@export_range(-1, 1000000, 1, "or_greater", "hide_slider") var seed: int = -1

@export_group("Penalties")

## Discourages repeating words already used. 1.0 is off. Above about 1.3 the text starts to read oddly.
@export_range(0.0, 2.0, 0.01) var repeat_penalty: float = 1.1

## How many of the most recent tokens the repeat penalty looks back over. 0 disables it.
@export_range(0, 2048, 1) var repeat_last_n: int = 64

## Penalty scaled by how often a word already appeared. Negative values encourage repetition.
@export_range(-2.0, 2.0, 0.01) var frequency_penalty: float = 0.0

## Flat penalty for any word that already appeared at all, which nudges the model onto new topics.
@export_range(-2.0, 2.0, 0.01) var presence_penalty: float = 0.0

@export_group("Mirostat")

## Adaptive sampling that targets a constant "surprise" level instead of a fixed top_p/top_k.
## Off is the normal choice. v2 is the cheaper of the two algorithms.
@export_enum("Off:0", "Mirostat v1:1", "Mirostat v2:2") var mirostat_mode: int = 0

## Target surprise (perplexity) Mirostat steers toward. Lower is more predictable text.
@export_range(0.0, 10.0, 0.1) var mirostat_tau: float = 5.0

## How fast Mirostat corrects toward the target. Higher reacts faster but wobbles more.
@export_range(0.0, 1.0, 0.01) var mirostat_eta: float = 0.1

## Window size used by Mirostat v1 only. Ignored by v2.
@export_range(1, 1000, 1) var mirostat_m: int = 100

@export_group("Backend")

## Which runtime executes the request. Leave it blank to follow the project's
## `local_agents/llm/backend` setting (use the inspector's revert arrow to clear it).
@export_enum("in_process", "llama_server") var backend: String = ""

## Ask the model to reply with strict JSON. Only useful when your prompt describes a JSON shape.
@export var output_json: bool = false

@export_subgroup("Server", "server_")

## Base URL of an already-running llama-server. Blank uses the project's `local_agents/llm/server_url`.
@export_placeholder("http://127.0.0.1:8080") var server_base_url: String = ""

## Bearer token for a server that requires one. It is stored as plain text in the saved `.tres` and
## shown unmasked in the inspector, so do not put a secret you care about here, and do not commit
## the file.
@export_placeholder("(sent as a bearer token)") var server_api_key: String = ""

## Model name to request from the server, for a server hosting several. Blank uses its default.
@export_placeholder("(server default)") var server_model: String = ""

## Give up on a single request after this long.
@export_range(1, 600, 1, "or_greater", "suffix:s") var server_timeout_sec: int = 120

## Pin this agent to one server slot so its KV cache is not shared. -1 lets the server choose.
@export_range(-1, 32, 1) var server_slot: int = -1

## Let the server reuse the cached prefix of a repeated prompt. Big speedup, so leave it on.
@export var server_cache_prompt: bool = true

## Launch llama-server automatically if nothing is listening on the base URL yet.
@export var server_autostart: bool = true

## Stop an auto-started server when the game quits. Turn off to keep a warm server between runs.
@export var server_shutdown_on_exit: bool = true

## How long to wait for an auto-started server process to appear before failing.
@export_range(0, 120000, 100, "or_greater", "suffix:ms") var server_start_timeout_ms: int = 30000

## How long to wait for the server to report ready once it is up.
@export_range(0, 60000, 100, "or_greater", "suffix:ms") var server_ready_timeout_ms: int = 1200

@export_group("Advanced")

## Extra JSON fields merged into the server request body. For backend features with no property here.
@export var server_extra_body: Dictionary = {}

## Extra key/value pairs merged into the emitted options, overriding anything above. Escape hatch.
@export var extra_options: Dictionary = {}

## Emits the options Dictionary the inference backends consume.
##
## Blank strings and sentinel values (-1 slot, non-positive timeouts) are omitted so the backend
## keeps its own default; `extra_options` is merged last and therefore wins over everything else.
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
    if server_base_url.strip_edges() != "":
        opts["server_base_url"] = server_base_url.strip_edges()
    if server_api_key.strip_edges() != "":
        opts["server_api_key"] = server_api_key.strip_edges()
    if server_model.strip_edges() != "":
        opts["server_model"] = server_model.strip_edges()
    if server_timeout_sec > 0:
        opts["server_timeout_sec"] = server_timeout_sec
    if server_slot >= 0:
        opts["id_slot"] = server_slot
    opts["cache_prompt"] = server_cache_prompt
    opts["server_autostart"] = server_autostart
    opts["server_shutdown_on_exit"] = server_shutdown_on_exit
    if server_start_timeout_ms > 0:
        opts["server_start_timeout_ms"] = server_start_timeout_ms
    if server_ready_timeout_ms > 0:
        opts["server_ready_timeout_ms"] = server_ready_timeout_ms
    if not server_extra_body.is_empty():
        opts["server_extra_body"] = server_extra_body.duplicate(true)
    if seed >= 0:
        opts["seed"] = seed
    for key in extra_options.keys():
        opts[key] = extra_options[key]
    return opts
