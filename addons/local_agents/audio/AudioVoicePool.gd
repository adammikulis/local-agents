@tool
extends Node3D
class_name LocalAgentsAudioVoicePool

## A fixed pool of reusable audio players with round-robin voice stealing and
## per-key cooldown rate limiting, so a burst of simultaneous events (e.g. many
## debris contacts in one frame) can't machine-gun the mixer.
##
## Positional events use pooled `AudioStreamPlayer3D` (spatialized); non-positional
## events (UI, music-adjacent one-shots) use pooled `AudioStreamPlayer`.

const DEFAULT_POSITIONAL := 12
const DEFAULT_NONPOSITIONAL := 6
const DEFAULT_COOLDOWN_MS := 45

var _positional: Array[AudioStreamPlayer3D] = []
var _nonpositional: Array[AudioStreamPlayer] = []
var _pos_idx: int = 0
var _nonpos_idx: int = 0
var _last_play_ms: Dictionary = {}     # cooldown_key -> ms of last accepted play
var _sfx_bus: StringName = &"Sfx"
var _ui_bus: StringName = &"Ui"

func configure(
	positional_count: int = DEFAULT_POSITIONAL,
	nonpositional_count: int = DEFAULT_NONPOSITIONAL,
	sfx_bus: StringName = &"Sfx",
	ui_bus: StringName = &"Ui"
) -> void:
	_sfx_bus = sfx_bus
	_ui_bus = ui_bus
	_clear_players()
	for i in maxi(1, positional_count):
		var p := AudioStreamPlayer3D.new()
		p.bus = _bus_or_master(_sfx_bus)
		p.unit_size = 8.0
		p.max_distance = 220.0
		add_child(p)
		_positional.append(p)
	for i in maxi(1, nonpositional_count):
		var p := AudioStreamPlayer.new()
		p.bus = _bus_or_master(_ui_bus)
		add_child(p)
		_nonpositional.append(p)

## Play a spatialized one-shot at `world_position`. Returns false if the stream is
## null or the cooldown suppressed it.
func play_positional(
	stream: AudioStream,
	world_position: Vector3,
	pitch: float = 1.0,
	volume_db: float = 0.0,
	cooldown_key: String = "",
	cooldown_ms: int = DEFAULT_COOLDOWN_MS
) -> bool:
	if stream == null:
		return false
	if not _cooldown_ok(cooldown_key, cooldown_ms):
		return false
	if _positional.is_empty():
		return false
	var player := _positional[_pos_idx]
	_pos_idx = (_pos_idx + 1) % _positional.size()
	player.stream = stream
	player.pitch_scale = clampf(pitch, 0.05, 4.0)
	player.volume_db = volume_db
	player.global_position = world_position
	player.play()
	return true

## Play a non-spatialized one-shot (UI, ambience). `bus` defaults to the UI bus.
func play_nonpositional(
	stream: AudioStream,
	pitch: float = 1.0,
	volume_db: float = 0.0,
	bus: StringName = &"",
	cooldown_key: String = "",
	cooldown_ms: int = DEFAULT_COOLDOWN_MS
) -> bool:
	if stream == null:
		return false
	if not _cooldown_ok(cooldown_key, cooldown_ms):
		return false
	if _nonpositional.is_empty():
		return false
	var player := _nonpositional[_nonpos_idx]
	_nonpos_idx = (_nonpos_idx + 1) % _nonpositional.size()
	player.stream = stream
	player.pitch_scale = clampf(pitch, 0.05, 4.0)
	player.volume_db = volume_db
	player.bus = _bus_or_master(bus if bus != &"" else _ui_bus)
	player.play()
	return true

func _cooldown_ok(cooldown_key: String, cooldown_ms: int) -> bool:
	if cooldown_key == "" or cooldown_ms <= 0:
		return true
	var now := Time.get_ticks_msec()
	var last := int(_last_play_ms.get(cooldown_key, -1000000))
	if now - last < cooldown_ms:
		return false
	_last_play_ms[cooldown_key] = now
	return true

func _bus_or_master(bus: StringName) -> StringName:
	if AudioServer.get_bus_index(String(bus)) < 0:
		return &"Master"
	return bus

func _clear_players() -> void:
	for p in _positional:
		if is_instance_valid(p):
			p.queue_free()
	for p in _nonpositional:
		if is_instance_valid(p):
			p.queue_free()
	_positional.clear()
	_nonpositional.clear()
	_pos_idx = 0
	_nonpos_idx = 0
