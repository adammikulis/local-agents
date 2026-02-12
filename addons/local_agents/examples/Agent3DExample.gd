extends Node3D
class_name LocalAgentsAgent3DExample

const ExtensionLoader := preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const RuntimeHealth := preload("res://addons/local_agents/runtime/RuntimeHealth.gd")
const RuntimePaths := preload("res://addons/local_agents/runtime/RuntimePaths.gd")

@onready var agent_3d: CharacterBody3D = %Agent3D
@onready var guidance_label: RichTextLabel = %GuidanceLabel
@onready var runtime_status_label: Label = %RuntimeStatusLabel
@onready var model_status_label: Label = %ModelStatusLabel
@onready var load_status_label: Label = %LoadStatusLabel
@onready var action_status_label: Label = %ActionStatusLabel
@onready var refresh_status_button: Button = %RefreshStatusButton
@onready var load_model_button: Button = %LoadModelButton
@onready var prompt_input: LineEdit = %PromptInput
@onready var send_button: Button = %SendButton
@onready var transcript_label: RichTextLabel = %TranscriptLabel

var _request_in_flight := false

func _ready() -> void:
    refresh_status_button.pressed.connect(_refresh_hud_status)
    load_model_button.pressed.connect(_on_load_model_pressed)
    send_button.pressed.connect(_on_send_pressed)
    prompt_input.text_submitted.connect(_on_prompt_submitted)

    if agent_3d and agent_3d.has_signal("model_output_received"):
        agent_3d.connect("model_output_received", Callable(self, "_on_agent_output"))

    transcript_label.clear()
    transcript_label.append_text("Agent3D demo ready. Use the HUD checklist before sending prompts.\n")
    _refresh_hud_status()

func _refresh_hud_status() -> void:
    var runtime_ready := ExtensionLoader.ensure_initialized()
    var runtime_state := RuntimeHealth.summarize()
    var runtime_text := String(runtime_state.get("runtime", "Runtime: unavailable"))
    if runtime_ready:
        runtime_status_label.text = runtime_text
    else:
        var runtime_error := ExtensionLoader.get_error()
        if runtime_error.is_empty():
            runtime_error = "Unavailable"
        runtime_status_label.text = "Runtime: %s" % runtime_error

    var default_model := RuntimePaths.resolve_default_model()
    var has_default_model := default_model != ""
    if has_default_model:
        model_status_label.text = "Model file: %s" % default_model.get_file()
    else:
        model_status_label.text = "Model file: Missing default model in user://local_agents/models"

    var runtime := _runtime_singleton(runtime_ready)
    var model_loaded := _is_model_loaded(runtime)
    load_status_label.text = "Runtime model: Loaded" if model_loaded else "Runtime model: Not loaded"

    load_model_button.disabled = not runtime_ready or not has_default_model or _request_in_flight
    send_button.disabled = not model_loaded or _request_in_flight

    guidance_label.text = _guidance_text(runtime_ready, has_default_model, model_loaded)

func _on_load_model_pressed() -> void:
    var runtime_ready := ExtensionLoader.ensure_initialized()
    var runtime := _runtime_singleton(runtime_ready)
    if runtime == null:
        action_status_label.text = "Action: Runtime unavailable. Build binaries and refresh."
        _refresh_hud_status()
        return

    var default_model := RuntimePaths.resolve_default_model()
    if default_model == "":
        action_status_label.text = "Action: No default GGUF found. Download one from Local Agents -> Downloads."
        _refresh_hud_status()
        return

    action_status_label.text = "Action: Loading model..."
    _request_in_flight = true
    _refresh_hud_status()

    var ok := false
    if runtime.has_method("load_model"):
        ok = bool(runtime.call("load_model", default_model, {}))

    _request_in_flight = false
    if ok:
        action_status_label.text = "Action: Model loaded. You can now send prompts."
    else:
        action_status_label.text = "Action: Model load failed. Check runtime binaries and model integrity."
    _refresh_hud_status()

func _on_send_pressed() -> void:
    _submit_prompt(prompt_input.text)

func _on_prompt_submitted(text: String) -> void:
    _submit_prompt(text)

func _submit_prompt(text: String) -> void:
    var prompt := text.strip_edges()
    if prompt.is_empty() or _request_in_flight:
        return

    var runtime := _runtime_singleton(ExtensionLoader.ensure_initialized())
    if not _is_model_loaded(runtime):
        action_status_label.text = "Action: Load a model first."
        _refresh_hud_status()
        return

    var controller := _agent_controller()
    if controller == null:
        action_status_label.text = "Action: Agent node is unavailable."
        _refresh_hud_status()
        return

    _request_in_flight = true
    prompt_input.clear()
    transcript_label.append_text("\nYou: %s\n" % prompt)
    action_status_label.text = "Action: Generating response..."
    _refresh_hud_status()

    var result: Dictionary = controller.call("think", prompt)
    _request_in_flight = false
    if not bool(result.get("ok", true)):
        action_status_label.text = "Action: Generation failed (%s)." % String(result.get("error", "unknown"))
    elif String(result.get("text", "")).is_empty():
        action_status_label.text = "Action: No output returned."
    else:
        action_status_label.text = "Action: Response received."
    _refresh_hud_status()

func _on_agent_output(text: String) -> void:
    var trimmed := text.strip_edges()
    if trimmed.is_empty():
        return
    transcript_label.append_text("Agent: %s\n" % trimmed)

func _runtime_singleton(runtime_ready: bool) -> Object:
    if not runtime_ready:
        return null
    if not Engine.has_singleton("AgentRuntime"):
        return null
    return Engine.get_singleton("AgentRuntime")

func _is_model_loaded(runtime: Object) -> bool:
    if runtime == null or not runtime.has_method("is_model_loaded"):
        return false
    return bool(runtime.call("is_model_loaded"))

func _agent_controller() -> Object:
    if agent_3d == null:
        return null
    return agent_3d.get("agent")

func _guidance_text(runtime_ready: bool, has_model: bool, model_loaded: bool) -> String:
    if not runtime_ready:
        return "[b]Step 1[/b] Build extension binaries and refresh status.\nExpected: Runtime label reports loaded/ready."
    if not has_model:
        return "[b]Step 2[/b] Open [i]Local Agents -> Downloads[/i] and fetch a GGUF model.\nExpected: Model file is detected under user://local_agents/models."
    if not model_loaded:
        return "[b]Step 3[/b] Press [i]Load Default Model[/i].\nExpected: Runtime model switches to Loaded."
    return "[b]Step 4[/b] Enter a prompt and press [i]Send[/i] to drive Agent3D output."
