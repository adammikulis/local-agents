class_name LAStreamerVoice
extends Node


signal speaking_started(text: String)

## The streamer's line is over. It drives the avatar's talk animation back to closed, and exactly one
## of these follows every `speaking_started`.
signal speaking_finished()

const SpeechEngineScript: GDScript = preload("res://addons/local_agents/runtime/audio/SpeechEngine.gd")
const VOICE_BUS: String = "Voice"

var _engine: Node = null   # LocalAgentSpeechEngine


## `options`: `gender` picks the voice ("male" or "female"), `enabled` starts it muted.
func setup(options: Dictionary = {}) -> void:
	_engine = SpeechEngineScript.new()
	_engine.name = "SpeechEngine"
	add_child(_engine)
	_engine.speaking_started.connect(_on_engine_started)
	_engine.speaking_finished.connect(_on_engine_finished)
	_engine.setup({
		"gender": String(options.get("gender", "male")),
		"enabled": bool(options.get("enabled", true)),
		"bus": VOICE_BUS,
	})


func set_gender(gender: String) -> void:
	if _engine != null:
		_engine.set_gender(gender)


func set_enabled(on: bool) -> void:
	if _engine != null:
		_engine.set_enabled(on)


## Set the streamer's volume in decibels. This moves the engine's own player, so it never touches a
## bus the rest of the project is mixing through.
func set_volume_db(db: float) -> void:
	if _engine != null:
		_engine.set_volume_db(db)


func is_speaking() -> bool:
	return _engine != null and _engine.is_speaking()


func speak(text: String) -> void:
	if _engine != null:
		_engine.speak(text)


func _on_engine_started(text: String) -> void:
	emit_signal("speaking_started", text)


func _on_engine_finished() -> void:
	emit_signal("speaking_finished")
