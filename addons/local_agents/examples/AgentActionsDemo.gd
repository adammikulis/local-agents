extends Node


@export var color_words: Dictionary[String, Color] = {}

## The orb's colour before anything happens, and what "reset" returns it to.
@export_color_no_alpha var neutral_color: Color = Color(0.3, 0.32, 0.4)

@onready var _agent: LocalAgent = %Agent
@onready var _orb: ColorRect = %Orb
@onready var _caption: Label = %Caption


# One place applies an action, whoever asked for it. Connected in the scene to Agent.action_requested.
func _on_agent_action_requested(action: String, params: Dictionary) -> void:
	match action:
		"set_color":
			var word: String = String(params.get("color", ""))
			_orb.color = color_words.get(word, neutral_color)
			_caption.text = "Orb colour: %s" % word
		"pulse":
			_orb.pivot_offset = _orb.size * 0.5
			var tween: Tween = create_tween()
			tween.tween_property(_orb, "scale", Vector2(1.25, 1.25), 0.15)
			tween.tween_property(_orb, "scale", Vector2.ONE, 0.25)
		"reset":
			_orb.color = neutral_color
			_caption.text = "Orb colour: neutral"


func _request(action: String, params: Dictionary) -> void:
	if _agent.is_runtime_ready():
		_agent.enqueue_action(action, params)
	else:
		_on_agent_action_requested(action, params)


func _on_colour_button_pressed(word: String) -> void:
	_request("set_color", {"color": word})


func _on_pulse_button_pressed() -> void:
	_request("pulse", {})


func _on_reset_button_pressed() -> void:
	_request("reset", {})


# A small local model does not answer in JSON, so its reply is scanned for the vocabulary rather
# than parsed. Connected in the scene to ChatPanel.reply_received.
func _on_reply_received(text: String) -> void:
	var lower: String = text.to_lower()
	for word in color_words:
		if lower.contains(word):
			_request("set_color", {"color": word})
			break
	if lower.contains("pulse"):
		_request("pulse", {})
