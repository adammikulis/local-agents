extends Node
class_name LocalAgentActionsDemo

## Ladder rung 2: the actions loop. This is the step that makes an agent more
## than a chatbot. Instead of only reading the model's text, we turn the reply
## into game actions: the agent calls enqueue_action(name, params), the wrapper
## re-emits action_requested(name, params), and the scene reacts by recoloring
## and pulsing an on-screen orb.
##
## The same buttons that the model "presses" are also wired to real buttons, so
## the actions -> effect loop is visible even with no model or runtime installed.

@onready var agent: LocalAgent = %Agent
@onready var prompt_input: LineEdit = %PromptInput
@onready var status_label: Label = %StatusLabel
@onready var log_label: RichTextLabel = %LogLabel
@onready var orb: ColorRect = %Orb
@onready var caption_label: Label = %CaptionLabel

const ExtensionLoader = preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
const RuntimePaths = preload("res://addons/local_agents/runtime/RuntimePaths.gd")

# The small, fixed vocabulary the agent is allowed to drive. Keeping the action
# set tiny and declarative is the whole point: the model picks from these, it
# does not write code.
const COLOR_WORDS: Dictionary = {
	"red": Color(0.9, 0.2, 0.2),
	"green": Color(0.2, 0.8, 0.3),
	"blue": Color(0.25, 0.5, 0.95),
	"yellow": Color(0.95, 0.85, 0.2),
	"orange": Color(0.95, 0.55, 0.15),
	"purple": Color(0.65, 0.3, 0.85),
	"white": Color(0.9, 0.9, 0.95),
}

var _busy: bool = false

func _ready() -> void:
	# Listen to the wrapper signal: every enqueue_action lands here as an action.
	agent.action_requested.connect(_on_action)
	prompt_input.text_submitted.connect(_on_submit)
	_wire_manual_buttons()
	orb.pivot_offset = orb.size * 0.5
	_refresh_status()

# --- The actions loop ---------------------------------------------------------

# One place applies actions to the scene, no matter who requested them (the LLM
# via think(), or a human via the manual buttons). New action names compose in
# by adding a branch here plus a value in the vocabulary above.
func _on_action(action: String, params: Dictionary) -> void:
	match action:
		"set_color":
			var key: String = String(params.get("color", "white"))
			var color: Color = COLOR_WORDS.get(key, Color(0.9, 0.9, 0.95))
			orb.color = color
			caption_label.text = "Orb color: %s" % key
			_log("action set_color -> %s" % key)
		"pulse":
			_pulse_orb()
			_log("action pulse")
		"reset":
			orb.color = Color(0.3, 0.32, 0.4)
			caption_label.text = "Orb color: neutral"
			_log("action reset")
		_:
			_log("action %s (no handler)" % action)

func _pulse_orb() -> void:
	orb.pivot_offset = orb.size * 0.5
	var tween: Tween = create_tween()
	tween.tween_property(orb, "scale", Vector2(1.25, 1.25), 0.15)
	tween.tween_property(orb, "scale", Vector2(1.0, 1.0), 0.25)

# --- LLM path -----------------------------------------------------------------

func _on_submit(text: String) -> void:
	var prompt: String = text.strip_edges()
	if prompt.is_empty() or _busy:
		return
	if not _ready_to_chat():
		_refresh_status()
		return
	_busy = true
	prompt_input.clear()
	_log("you: %s" % prompt)
	# Steer the model toward the action vocabulary. A small local model does not
	# need perfect obedience: we scan whatever it replies for known keywords.
	var framed: String = (
		"You control a glowing orb. Reply with a short instruction that names a "
		+ "color (red, green, blue, yellow, orange, purple, white) and optionally "
		+ "the word pulse. Request: %s" % prompt
	)
	var result: Dictionary = agent.think(framed)
	_busy = false
	if not bool(result.get("ok", true)):
		_log("generation failed: %s" % String(result.get("error", "unknown")))
		_refresh_status()
		return
	var reply: String = String(result.get("text", ""))
	if not reply.is_empty():
		_log("agent: %s" % reply)
	_drive_actions_from_text(reply)
	_refresh_status()

# Translate free-form model text into concrete actions. This is deliberately
# forgiving so the demo works with tiny models.
func _drive_actions_from_text(text: String) -> void:
	var lower: String = text.to_lower()
	var matched: bool = false
	for word in COLOR_WORDS.keys():
		if lower.find(word) != -1:
			agent.enqueue_action("set_color", {"color": word})
			matched = true
			break
	if lower.find("pulse") != -1:
		agent.enqueue_action("pulse", {})
		matched = true
	if not matched:
		_log("no known action in reply; try naming a color")

# --- Manual buttons (work with no model) -------------------------------------

func _wire_manual_buttons() -> void:
	var buttons: Node = %ManualButtons
	for word in ["red", "green", "blue"]:
		var button: Button = buttons.get_node(word.capitalize()) as Button
		if button != null:
			button.pressed.connect(_on_manual_color.bind(word))
	var pulse_button: Button = buttons.get_node("Pulse") as Button
	if pulse_button != null:
		pulse_button.pressed.connect(func() -> void: agent.enqueue_action("pulse", {}))
	var reset_button: Button = buttons.get_node("Reset") as Button
	if reset_button != null:
		reset_button.pressed.connect(func() -> void: agent.enqueue_action("reset", {}))

func _on_manual_color(word: String) -> void:
	# Exactly the same call the model makes: enqueue_action -> action_requested.
	agent.enqueue_action("set_color", {"color": word})

# --- Status + logging (mirrors AgentQuickstart) ------------------------------

func _log(line: String) -> void:
	log_label.append_text(line + "\n")

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
		status_label.text = "No native runtime (%s). The manual buttons still drive the actions loop." % runtime_error
		return
	var default_model: String = RuntimePaths.resolve_default_model()
	if default_model.is_empty():
		status_label.text = "No GGUF model found. The manual buttons still work; add a model to let the agent drive it."
		return
	status_label.text = "Ready: %s. Type a request, or press a button to fire an action." % default_model.get_file()
