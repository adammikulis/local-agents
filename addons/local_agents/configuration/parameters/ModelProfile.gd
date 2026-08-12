extends Resource
class_name LocalAgentModelProfile


@export_group("Model")

## Human-readable label for this profile, shown wherever profiles are listed. Purely cosmetic.
@export var profile_name: String = ""

## The GGUF weights to load. Absolute paths work, and so does a `res://` path for a model you ship.
## Leave blank to fall back to the project's `local_agents/model/default_path` setting.
@export_file("*.gguf") var model_path: String = ""

@export_group("Loading")

## Context window in tokens. Bigger means the model remembers more of the conversation but uses
## much more memory. 0 keeps whatever the model file itself declares.
@export_range(0, 131072, 256, "or_greater", "suffix:tok") var context_size: int = 4096

## CPU threads used for inference. 0 lets the runtime pick (usually your core count).
@export_range(0, 64, 1) var threads: int = 0

## How many transformer layers to offload to the GPU. 0 is CPU only. Set it high (e.g. 99) to push
## the whole model onto the GPU. Too high for your VRAM and loading fails.
@export_range(0, 128, 1) var gpu_layers: int = 0

@export_group("Prompting")

## Standing instruction prepended to every conversation with this model ("You are a terse guide…").
## Leave blank for none.
@export_multiline var system_prompt: String = ""

@export_group("Chat template")

## Optional Jinja chat template overriding the one baked into the GGUF. Only needed when a model
## ships a broken or missing template. Leave blank otherwise.
@export_multiline var chat_template: String = ""

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
