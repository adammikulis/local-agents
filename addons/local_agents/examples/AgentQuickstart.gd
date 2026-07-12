extends Node
class_name LocalAgentQuickstart

## The smallest possible "talk to a local LLM" demo: one LocalAgent node, a
## prompt box, and a reply label. Type a message, press enter, read the model's reply.

@onready var agent: LocalAgent = %Agent
@onready var prompt_input: LineEdit = %PromptInput
@onready var reply_label: RichTextLabel = %ReplyLabel
@onready var status_label: Label = %StatusLabel

const ExtensionLoader = preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const RuntimePaths = preload("res://addons/local_agents/runtime/RuntimePaths.gd")

var _busy: bool = false

func _ready() -> void:
	agent.model_output_received.connect(_on_reply)
	prompt_input.text_submitted.connect(_on_submit)
	_refresh_status()

func _on_submit(text: String) -> void:
	var prompt: String = text.strip_edges()
	if prompt.is_empty() or _busy:
		return
	if not _ready_to_chat():
		_refresh_status()
		return
	_busy = true
	prompt_input.clear()
	reply_label.text = "Thinking..."
	# think() records the prompt, runs the local model, and emits model_output_received.
	var result: Dictionary = agent.think(prompt)
	_busy = false
	if not bool(result.get("ok", true)):
		reply_label.text = "Generation failed: %s" % String(result.get("error", "unknown"))
	_refresh_status()

func _on_reply(text: String) -> void:
	reply_label.text = text

# Ensure the native runtime is live and a GGUF model is loaded before generating.
func _ready_to_chat() -> bool:
	if not ExtensionLoader.ensure_initialized():
		return false
	if agent.agent_node == null:
		return false
	var model_path: String = String(agent.agent_node.get_default_model_path()).strip_edges()
	if model_path.is_empty():
		return false
	if agent.agent_node.has_method("is_model_loaded") and bool(agent.agent_node.call("is_model_loaded")):
		return true
	return bool(agent.agent_node.load_model(model_path, {}))

func _refresh_status() -> void:
	if not ExtensionLoader.ensure_initialized():
		var runtime_error: String = ExtensionLoader.get_error()
		if runtime_error.is_empty():
			runtime_error = "unavailable"
		status_label.text = "Native runtime missing (%s). Build or download the extension binary (see README)." % runtime_error
		return
	var default_model: String = RuntimePaths.resolve_default_model()
	if default_model.is_empty():
		status_label.text = "No GGUF model found. Open the editor Local Agents -> Downloads panel to fetch one."
		return
	status_label.text = "Ready: %s. Type a prompt and press enter." % default_model.get_file()
