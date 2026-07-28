extends Resource
class_name LocalAgentModelProfile

## Design-time description of ONE local model: which `.gguf` file to load, and how to load it.
##
## This is the schema half of the model configuration — save a `.tres` next to your project, pick
## the file in the inspector, and the runtime reads it. It deliberately holds only load-time knobs
## (file, context window, threads, GPU offload, prompts). Per-agent behaviour (voice, database
## path, tick rate) belongs on the LocalAgent node itself, and sampling knobs (temperature, top_p,
## penalties) belong on LocalAgentInferenceParams — keeping the three apart means one model profile
## can be shared by every agent in a scene.
##
## `to_options()` emits the Dictionary the llama runtime consumes, so a profile can be handed
## straight to LocalAgentLlamaServerManager.ensure_running() or merged into an agent's inference
## options. Zero-valued knobs are omitted so the runtime keeps its own default for them.

@export_group("Model")

## Human-readable label for this profile, shown wherever profiles are listed. Purely cosmetic.
@export var profile_name: String = ""

## The GGUF weights to load. Absolute paths work; so does a `res://` path for a model you ship.
## Leave blank to fall back to the project's `local_agents/model/default_path` setting.
@export_file("*.gguf") var model_path: String = ""

@export_group("Loading")

## Context window in tokens. Bigger means the model remembers more of the conversation but uses
## much more memory. 0 keeps whatever the model file itself declares.
@export_range(0, 131072, 256, "or_greater", "suffix:tok") var context_size: int = 4096

## CPU threads used for inference. 0 lets the runtime pick (usually your core count).
@export_range(0, 64, 1) var threads: int = 0

## How many transformer layers to offload to the GPU. 0 is CPU only; set it high (e.g. 99) to push
## the whole model onto the GPU. Too high for your VRAM and loading fails.
@export_range(0, 128, 1) var gpu_layers: int = 0

@export_group("Prompting")

## Standing instruction prepended to every conversation with this model ("You are a terse guide…").
## Leave blank for none.
@export_multiline var system_prompt: String = ""

@export_group("Chat template")

## Optional Jinja chat template overriding the one baked into the GGUF. Only needed when a model
## ships a broken or missing template — leave blank otherwise.
@export_multiline var chat_template: String = ""

## Emits the load-time options Dictionary for the llama runtime.
##
## Keys match what LocalAgentLlamaServerManager reads: `context_size`, `threads`, `n_gpu_layers`,
## plus `system_prompt` / `chat_template` for whichever cognition path wants them. Zero and blank
## values are OMITTED rather than sent as 0, so the runtime keeps its own default for that knob.
func to_options() -> Dictionary:
    var opts: Dictionary = {}
    if context_size > 0:
        opts["context_size"] = context_size
    if threads > 0:
        opts["threads"] = threads
    if gpu_layers > 0:
        opts["n_gpu_layers"] = gpu_layers
    if system_prompt.strip_edges() != "":
        opts["system_prompt"] = system_prompt
    if chat_template.strip_edges() != "":
        opts["chat_template"] = chat_template
    return opts
