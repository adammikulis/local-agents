extends Resource
class_name LocalAgentModelProfile


@export_group("Model")

@export var profile_name: String = ""

@export_file("*.gguf") var model_path: String = ""

@export_group("Loading")

## Context window in tokens. Bigger means the model remembers more of the conversation but uses
## much more memory. 0 keeps whatever the model file itself declares.
@export_range(0, 131072, 256, "or_greater", "suffix:tok") var context_size: int = 4096

## CPU threads used for inference. 0 lets the runtime pick (usually your core count).
@export_range(0, 64, 1) var threads: int = 0

@export_range(0, 128, 1) var gpu_layers: int = 0

@export_group("Prompting")

@export_multiline var system_prompt: String = ""

@export_group("Chat template")

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
