class_name LAStreamerVoice
extends Node

## The streamer's mouth. One commentary line at a time, serialized so the caster never talks over
## itself.
##
## Synthesis lives in addons/local_agents/runtime/audio/SpeechEngine.gd; this file is an adapter over that
## node. set_volume_db() moves the engine's own player, not an audio bus.
##
## Playback routes to the "Voice" audio bus when the project defines one, so speech volume is
## independent of music and effects.
##
## (Explicit types only, project rule: no ':=' inferred typing.)

## The streamer has started a line. `text` is that line.
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


## Switch the streamer's voice by gender, "male" or "female". Downloads that voice if it is not
## already on disk, and the lines spoken while it downloads use the system voice.
func set_gender(gender: String) -> void:
	if _engine != null:
		_engine.set_gender(gender)


## Mute or unmute the streamer. Muting stops the current line and ends its beat, so an avatar
## listening for `speaking_finished` closes its mouth instead of holding it open.
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


## Queue a line. A backlog keeps only the freshest lines, so commentary stays in sync with the sim
## rather than narrating the distant past.
func speak(text: String) -> void:
	if _engine != null:
		_engine.speak(text)


func _on_engine_started(text: String) -> void:
	emit_signal("speaking_started", text)


func _on_engine_finished() -> void:
	emit_signal("speaking_finished")
