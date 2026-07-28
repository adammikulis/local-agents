extends Node3D
class_name LocalAgent3DExample

## Minimal "prove the runtime works" demo: a status checklist, a Load Model button, and a prompt box.
##
## Everything it knows about readiness comes from ONE `LocalAgentStatus.check()` call. It used to
## reimplement that probe inline — `Engine.get_singleton("AgentRuntime")` reflection, its own
## `is_model_loaded` poke, its own model-path resolution and its own four-way guidance ladder — which
## is precisely the duplication `LocalAgentStatus` exists to end.
##
## (Explicit types only — project rule: no ':=' inferred typing.)

const Status: GDScript = preload("res://addons/local_agents/runtime/AgentStatus.gd")

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

var _request_in_flight: bool = false

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
    var state: Dictionary = Status.check()

    runtime_status_label.text = String(state["headline"])
    var extension_error: String = String(state["extension_error"])
    if not bool(state["extension_ok"]) and extension_error != "":
        runtime_status_label.tooltip_text = extension_error
    else:
        runtime_status_label.tooltip_text = String(state["expected_library_path"])

    var model_path: String = String(state["model_path"])
    if model_path == "":
        model_status_label.text = "Model file: none found"
        model_status_label.tooltip_text = "Checked: %s" % ", ".join(state["model_candidates"])
    else:
        model_status_label.text = "Model file: %s" % model_path.get_file()
        model_status_label.tooltip_text = model_path

    var model_loaded: bool = bool(state["model_loaded"])
    load_status_label.text = "Runtime model: Loaded" if model_loaded else "Runtime model: Not loaded"

    load_model_button.disabled = not bool(state["extension_ok"]) or model_path == "" or _request_in_flight
    send_button.disabled = not model_loaded or _request_in_flight

    guidance_label.text = _guidance_text(state)

# The ladder is data, not branches: blockers come back from LocalAgentStatus already ordered by fix
# order, so the first one IS the current step and its fix sentence is already written.
func _guidance_text(state: Dictionary) -> String:
    var blockers: PackedStringArray = state["blockers"]
    if blockers.is_empty():
        return "[b]Ready[/b] Enter a prompt and press [i]Send[/i] to drive Agent3D output."
    var total_steps: int = blockers.size()
    return "[b]Step 1 of %d[/b] %s" % [total_steps, String(state["next_step"])]

func _on_load_model_pressed() -> void:
    action_status_label.text = "Action: Loading model..."
    _request_in_flight = true
    _refresh_hud_status()

    var ok: bool = Status.ensure_model_loaded()

    _request_in_flight = false
    if ok:
        action_status_label.text = "Action: Model loaded. You can now send prompts."
    else:
        action_status_label.text = "Action: %s" % Status.next_step()
    _refresh_hud_status()

func _on_send_pressed() -> void:
    _submit_prompt(prompt_input.text)

func _on_prompt_submitted(text: String) -> void:
    _submit_prompt(text)

func _submit_prompt(text: String) -> void:
    var prompt: String = text.strip_edges()
    if prompt.is_empty() or _request_in_flight:
        return

    # Gate on blockers, NOT on is_ready(). is_ready() means level == READY, and the level drops to
    # DEGRADED for advisory warnings like a missing Piper voice or a missing godot_voxel — neither of
    # which stops the model answering. Gating on it refused to send on a perfectly working setup, and
    # since blockers was empty, next_step() returned "" so the label just read "Action: ".
    var state: Dictionary = Status.check()
    var blockers: PackedStringArray = state["blockers"]
    if not blockers.is_empty():
        action_status_label.text = "Action: %s" % String(state["next_step"])
        _refresh_hud_status()
        return

    var controller: Object = _agent_controller()
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
    var trimmed: String = text.strip_edges()
    if trimmed.is_empty():
        return
    transcript_label.append_text("Agent: %s\n" % trimmed)

func _agent_controller() -> Object:
    if agent_3d == null:
        return null
    return agent_3d.get("agent")
