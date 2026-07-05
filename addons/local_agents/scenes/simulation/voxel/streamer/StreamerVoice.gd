class_name LAStreamerVoice
extends Node

## The streamer's mouth. Speaks one commentary line at a time through neural Piper TTS, serialized so
## the caster never talks over itself. Real Piper is the voice of record: we drive the installed
## `piper` Python module (`python -m piper -m <voice>.onnx -f out.wav -i line.txt`) OFF the main
## thread, because the native AgentRuntime.synthesize_speech path needs a piper *binary* in the
## runtime dir that this checkout does not ship. If the voice model is missing it is auto-downloaded
## once from rhasspy/piper-voices. Godot's built-in DisplayServer TTS is a last-resort stopgap used
## only while that download is in flight or if Piper cannot run at all.
##
## Playback routes to a dedicated "Voice" audio bus so speech volume is independent of music/sfx.
## `speaking_started`/`speaking_finished` drive the avatar's talk animation.
##
## (Explicit types only — project rule: no ':=' inferred typing.)

signal speaking_started(text: String)
signal speaking_finished()

const VOICE_BUS: String = "Voice"
const VOICE_DIR: String = "user://local_agents/voices"
const PYTHON_CANDIDATES: Array = ["python3", "python"]
const MAX_QUEUE: int = 2   # drop the oldest pending line rather than let a backlog build

# Per-gender Piper voices (auto-downloaded from rhasspy/piper-voices on first use).
const VOICES: Dictionary = {
	"male": {"id": "en_US-ryan-medium", "url": "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/medium"},
	"female": {"id": "en_US-hfc_female-medium", "url": "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/hfc_female/medium"},
}
var _voice_id: String = "en_US-ryan-medium"
var _voice_url_base: String = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/medium"

var _enabled: bool = true
var _headless: bool = false
var _player: AudioStreamPlayer = null

var _python: String = ""            # resolved interpreter that can `import piper`, "" if none
var _voice_onnx: String = ""        # absolute path once the model is on disk
var _voice_json: String = ""
var _probe_thread: Thread = null

var _queue: Array = []              # pending commentary lines (strings)
var _busy: bool = false
var _synth_thread: Thread = null
var _synth_out: String = ""

# --- voice model download state ---
var _dl_http: HTTPRequest = null
var _dl_stage: String = ""          # "" | "json" | "onnx" | "done" | "failed"
var _dl_onnx_path: String = ""
var _dl_json_path: String = ""


func setup(options: Dictionary = {}) -> void:
	_enabled = bool(options.get("enabled", true))
	_headless = DisplayServer.get_name() == "headless"
	var preset: Dictionary = VOICES.get(String(options.get("gender", "male")), VOICES["male"])
	_voice_id = String(preset["id"])
	_voice_url_base = String(preset["url"])

	_player = AudioStreamPlayer.new()
	_player.name = "VoicePlayer"
	if AudioServer.get_bus_index(VOICE_BUS) >= 0:
		_player.bus = VOICE_BUS
	_player.finished.connect(_on_play_finished)
	add_child(_player)

	# Voice already installed? (checked-in under res://voices or previously downloaded under user://)
	_resolve_installed_voice()

	if _headless:
		return   # no audio device; the director still produces text lines for smoke output

	# Probe for a python that can run piper, off-thread so scene start never blocks on process spawns.
	_probe_thread = Thread.new()
	_probe_thread.start(Callable(self, "_probe_python"))

	# Fetch the voice model if we do not have one yet.
	if _voice_onnx == "":
		_begin_voice_download()


## Switch the streamer's voice by gender ("male"/"female"); downloads that voice if not present.
func set_gender(gender: String) -> void:
	var preset: Dictionary = VOICES.get(gender, VOICES["male"])
	if String(preset["id"]) == _voice_id:
		return
	_voice_id = String(preset["id"])
	_voice_url_base = String(preset["url"])
	_voice_onnx = ""
	_voice_json = ""
	if _dl_http != null and is_instance_valid(_dl_http):
		_dl_http.queue_free()
		_dl_http = null
	_dl_stage = ""
	_resolve_installed_voice()
	if _voice_onnx == "" and not _headless:
		_begin_voice_download()


func set_enabled(on: bool) -> void:
	_enabled = on
	if not on:
		_queue.clear()
		if _player != null and _player.playing:
			_player.stop()
		if _headless == false:
			DisplayServer.tts_stop()
		# Note: an in-flight synth thread still finishes; its result is dropped in _on_synth_done.


func set_volume_db(db: float) -> void:
	var idx: int = AudioServer.get_bus_index(VOICE_BUS)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, db)


func is_speaking() -> bool:
	return _busy or _queue.size() > 0


## Queue a line to be spoken. Serialized; if the caster is backed up we keep only the freshest lines
## so commentary stays in sync with the sim rather than narrating the distant past.
func speak(text: String) -> void:
	if not _enabled:
		return
	var line: String = text.strip_edges()
	if line == "":
		return
	_queue.append(line)
	while _queue.size() > MAX_QUEUE:
		_queue.pop_front()
	_pump()


func _pump() -> void:
	if _busy or _queue.is_empty():
		return
	var line: String = String(_queue.pop_front())
	_busy = true

	if _headless:
		# No audio in headless: report the beat instantly so any avatar logic stays consistent.
		emit_signal("speaking_started", line)
		call_deferred("_finish_speaking")
		return

	if _python != "" and _voice_onnx != "":
		emit_signal("speaking_started", line)
		_synth_out = _make_output_path()
		_synth_thread = Thread.new()
		_synth_thread.start(Callable(self, "_synthesize").bind(line, _synth_out))
		return

	# Piper not ready yet (voice still downloading / no python): stopgap on the OS voice so the stream
	# is never silent. Real Piper takes over automatically once installed.
	if _speak_os(line):
		emit_signal("speaking_started", line)
		# DisplayServer TTS has no reliable finished signal here; release after a rough duration.
		var secs: float = clampf(float(line.length()) * 0.06, 1.2, 8.0)
		get_tree().create_timer(secs).timeout.connect(_finish_speaking, CONNECT_ONE_SHOT)
	else:
		_finish_speaking()


# --- Piper synthesis (worker thread) ------------------------------------------------------------

func _synthesize(line: String, out_wav: String) -> void:
	# Piper reads the text from a file (OS.execute cannot pipe stdin), writes a WAV to out_wav.
	var txt_path: String = out_wav.get_basename() + ".txt"
	var f: FileAccess = FileAccess.open(txt_path, FileAccess.WRITE)
	if f == null:
		call_deferred("_on_synth_done", "")
		return
	f.store_string(line)
	f.close()

	var args: PackedStringArray = PackedStringArray([
		"-m", "piper",
		"-m", ProjectSettings.globalize_path(_voice_onnx),
		"-f", ProjectSettings.globalize_path(out_wav),
		"-i", ProjectSettings.globalize_path(txt_path),
	])
	if _voice_json != "":
		args.append("-c")
		args.append(ProjectSettings.globalize_path(_voice_json))

	var output: Array = []
	var code: int = OS.execute(_python, args, output, true)
	var abs_out: String = ProjectSettings.globalize_path(out_wav)
	if code == 0 and FileAccess.file_exists(abs_out):
		call_deferred("_on_synth_done", out_wav)
	else:
		call_deferred("_on_synth_done", "")


func _on_synth_done(out_wav: String) -> void:
	if _synth_thread != null:
		_synth_thread.wait_to_finish()
		_synth_thread = null
	if not _enabled or out_wav == "" or _player == null:
		_finish_speaking()
		return
	var stream: AudioStreamWAV = _load_wav(out_wav)
	if stream == null:
		_finish_speaking()
		return
	_player.stream = stream
	_player.play()   # _on_play_finished() releases the beat


func _on_play_finished() -> void:
	_finish_speaking()


func _finish_speaking() -> void:
	_busy = false
	emit_signal("speaking_finished")
	_pump()


func _load_wav(path: String) -> AudioStreamWAV:
	var abs_path: String = ProjectSettings.globalize_path(path)
	# Godot 4.4+ parses a runtime .wav directly (no import step needed).
	var s = AudioStreamWAV.load_from_file(abs_path)
	if s is AudioStreamWAV:
		return s as AudioStreamWAV
	return null


func _make_output_path() -> String:
	var dir: String = "user://local_agents/tts"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	# No Time.get_ticks in name races here (single-flight); a fixed name is fine and self-cleans.
	return "%s/streamer_line.wav" % dir


# --- OS TTS stopgap -----------------------------------------------------------------------------

func _speak_os(line: String) -> bool:
	var voices: Array = DisplayServer.tts_get_voices()
	if voices.is_empty():
		return false
	var voice_id: String = ""
	for v in voices:
		if v is Dictionary and String((v as Dictionary).get("language", "")).begins_with("en"):
			voice_id = String((v as Dictionary).get("id", ""))
			break
	if voice_id == "" and voices[0] is Dictionary:
		voice_id = String((voices[0] as Dictionary).get("id", ""))
	if voice_id == "":
		return false
	DisplayServer.tts_speak(line, voice_id)
	return true


# --- python resolution (worker thread) ----------------------------------------------------------

func _probe_python() -> void:
	var found: String = ""
	for cand in PYTHON_CANDIDATES:
		var output: Array = []
		var code: int = OS.execute(String(cand), PackedStringArray(["-c", "import piper"]), output, true)
		if code == 0:
			found = String(cand)
			break
	call_deferred("_on_python_probed", found)


func _on_python_probed(python: String) -> void:
	if _probe_thread != null:
		_probe_thread.wait_to_finish()
		_probe_thread = null
	_python = python


# --- voice model download -----------------------------------------------------------------------

func _resolve_installed_voice() -> void:
	# Prefer a previously-downloaded copy under user://, then a checked-in copy under res://.
	var roots: Array = [VOICE_DIR, LocalAgentsRuntimePaths.VOICES_RES_ROOT]
	for root in roots:
		var onnx: String = "%s/%s.onnx" % [root, _voice_id]
		if FileAccess.file_exists(ProjectSettings.globalize_path(onnx)):
			_voice_onnx = onnx
			var json: String = onnx + ".json"
			if FileAccess.file_exists(ProjectSettings.globalize_path(json)):
				_voice_json = json
			return


func _begin_voice_download() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(VOICE_DIR))
	_dl_onnx_path = "%s/%s.onnx" % [VOICE_DIR, _voice_id]
	_dl_json_path = "%s/%s.onnx.json" % [VOICE_DIR, _voice_id]
	_dl_http = HTTPRequest.new()
	add_child(_dl_http)
	_dl_http.request_completed.connect(_on_download_completed)
	# Small config first, then the big model.
	_dl_stage = "json"
	_dl_http.download_file = ProjectSettings.globalize_path(_dl_json_path)
	var err: int = _dl_http.request("%s/%s.onnx.json" % [_voice_url_base, _voice_id])
	if err != OK:
		_dl_stage = "failed"


func _on_download_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	var ok: bool = result == HTTPRequest.RESULT_SUCCESS and response_code >= 200 and response_code < 300
	if not ok:
		_dl_stage = "failed"
		return
	if _dl_stage == "json":
		_dl_stage = "onnx"
		_dl_http.download_file = ProjectSettings.globalize_path(_dl_onnx_path)
		var err: int = _dl_http.request("%s/%s.onnx" % [_voice_url_base, _voice_id])
		if err != OK:
			_dl_stage = "failed"
		return
	if _dl_stage == "onnx":
		_dl_stage = "done"
		_voice_json = _dl_json_path
		_voice_onnx = _dl_onnx_path   # from here on, speak() uses real Piper
		if _dl_http != null:
			_dl_http.queue_free()
			_dl_http = null
