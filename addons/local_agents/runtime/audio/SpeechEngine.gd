@tool
class_name LocalAgentSpeechEngine
extends Node

## The one place Local Agents turns text into sound.
##
## Three backends are tried in this order, all against the same voice model:
##
## 1. the `piper` binary in the addon's runtime directory, driven through AgentRuntime.synthesize_speech
## 2. the piper Python module, run as `python -m piper` off the main thread
## 3. Godot's DisplayServer text to speech, meaning the system voice
##
## If none of them can run, one warning is pushed and the call reports false.
##
## Step 1 is preferred, but the addon does not ship a piper binary, so on a stock install step 2 is
## what actually speaks. That path was written for the streamer overlay and lived in
## sim/streamer/StreamerVoice.gd, where LocalAgent.speak() could not reach it. It lives here now, and
## StreamerVoice is a thin adapter over this node.
##
## The voice model is a Piper .onnx. It is looked up under user://local_agents/voices and
## res://addons/local_agents/voices, and downloaded once from rhasspy/piper-voices when neither has
## it. That download is asynchronous, so lines spoken while it runs use the system voice and the
## next ones use Piper.
##
## Two ways in, because the two callers need different things:
##
## - `speak(text)` queues a line and returns immediately. Lines are serialized so the speaker never
##   talks over itself, and only the freshest MAX_QUEUE lines survive a backlog.
## - `speak_blocking(text)` synthesizes on the calling thread and returns whether audio was produced.
##   It blocks for the length of a piper invocation, so call it from a menu or a turn, not _process.
##
## The two share one speaker and speak_blocking wins. An explicit speak() ends whatever is talking, drops
## the queued backlog, and lets a synthesis already in flight land on the floor. Making speak() wait
## instead cannot work: a queued line ends on a deferred call, which only runs once the caller has
## returned to the main loop, so waiting inside speak() would deadlock.
##
## Playback goes to the `bus` named in setup() when that bus exists, so speech volume stays
## independent of music and effects. `speaking_started` and `speaking_finished` drive avatar mouths.
##
## (Explicit types only, project rule: no ':=' inferred typing.)

## A line has started. `text` is that line, stripped of surrounding whitespace.
signal speaking_started(text: String)

## The line that started is over. It played to the end, or speak_blocking cut it off, or no backend
## would take it. Exactly one of these follows every `speaking_started`.
signal speaking_finished()

const RuntimePaths: GDScript = preload("res://addons/local_agents/runtime/RuntimePaths.gd")

const DEFAULT_BUS: String = "Voice"
const VOICE_USER_DIR: String = "user://local_agents/voices"
const TTS_OUT_DIR: String = "user://local_agents/tts"
const VOICE_REPO: String = "https://huggingface.co/rhasspy/piper-voices/resolve/main"
const PYTHON_CANDIDATES: Array = ["python3", "python"]
const DEFAULT_VOICE: String = "en_US-ryan-medium"
const MAX_QUEUE: int = 2      # drop the oldest pending line rather than let a backlog build
const OUT_SLOTS: int = 4      # rotate output files so a finished wav is never overwritten mid load

# Gender is the only voice shorthand the streamer overlay offers. Everything else takes a full Piper
# voice id, which is also what the download URL is derived from.
const GENDER_VOICES: Dictionary = {
	"male": "en_US-ryan-medium",
	"female": "en_US-hfc_female-medium",
}

# Which interpreter can `import piper`, resolved once per process so every LocalAgent in a scene does
# not re-run the probe.
static var _python_cache: String = ""
static var _python_cache_valid: bool = false

# One counter for the whole process, so every engine gets its own output-file name. Rotating slots
# alone is not enough: an agent's engine and the streamer's engine both start at slot 0, so they
# would write the same wav while the other one is still loading it.
static var _engine_seq: int = 0

var _enabled: bool = true
var _headless: bool = false
var _auto_download: bool = true
var _runtime_dir: String = ""
var _native_bin: String = ""        # absolute path to a piper binary, "" when there is none
var _voice_id: String = DEFAULT_VOICE
var _voice_onnx: String = ""        # absolute path once the model is on disk
var _voice_json: String = ""
var _player: AudioStreamPlayer = null

var _python: String = ""            # interpreter that can `import piper`, "" if none
var _python_probed: bool = false
var _probe_thread: Thread = null
var _probe_result: String = ""

var _queue: Array = []              # pending lines (strings)
var _busy: bool = false
var _synth_thread: Thread = null
var _out_slot: int = 0
var _out_prefix: String = ""        # unique per engine, see _engine_seq
var _generation: int = 0            # which line owns the speaker. A stale callback drops its result
var _warned: bool = false


func _init() -> void:
	_engine_seq += 1
	_out_prefix = "speech_%d" % _engine_seq

# --- voice model download state ---
var _dl_http: HTTPRequest = null
var _dl_stage: String = ""          # "" | "json" | "onnx" | "done" | "failed"
var _dl_onnx_path: String = ""
var _dl_json_path: String = ""


## Bring the engine up. Add it to the tree first, then call this: it parents an AudioStreamPlayer and
## an HTTPRequest under itself.
##
## Options, all optional: `voice_id` (a Piper voice id, a res:// or user:// path, or an absolute path
## to an .onnx), `gender` ("male" or "female", a shorthand for voice_id), `runtime_directory` (where
## to look for a piper binary), `bus` (audio bus name, default "Voice"), `enabled`, `auto_download`.
func setup(options: Dictionary = {}) -> void:
	_enabled = bool(options.get("enabled", true))
	_headless = DisplayServer.get_name() == "headless"
	_auto_download = bool(options.get("auto_download", true))
	_runtime_dir = String(options.get("runtime_directory", ""))
	_native_bin = RuntimePaths.resolve_executable("piper", _runtime_dir)
	_voice_id = _requested_voice(options)

	var bus_name: String = String(options.get("bus", DEFAULT_BUS))
	_player = AudioStreamPlayer.new()
	_player.name = "SpeechPlayer"
	if AudioServer.get_bus_index(bus_name) >= 0:
		_player.bus = bus_name
	_player.finished.connect(_on_play_finished)
	add_child(_player)

	_resolve_installed_voice()

	if _headless:
		# No audio device and no frames to spare: skip the background probe and the 63 MB download.
		# speak_blocking() still probes on demand, so a headless test can synthesize a wav.
		return

	_start_python_probe()
	if _voice_onnx == "" and _auto_download:
		_begin_voice_download()


## Join the workers on teardown. Godot errors on a Thread that is freed while running, and a probe or
## a synthesis can still be in flight when the scene closes.
func _exit_tree() -> void:
	if _probe_thread != null and _probe_thread.is_started():
		_probe_thread.wait_to_finish()
	_probe_thread = null
	if _synth_thread != null and _synth_thread.is_started():
		_synth_thread.wait_to_finish()
	_synth_thread = null


## Switch voice by full Piper id. Downloads the model if it is not already on disk.
func set_voice(voice_id: String) -> void:
	var wanted: String = voice_id.strip_edges()
	if wanted == "":
		wanted = DEFAULT_VOICE
	# Same id is a no-op even when the model is still downloading. Re-resolving it would cancel that
	# download and start it again, which is what happens if a caller syncs the voice on every line.
	if wanted == _voice_id:
		return
	_voice_id = wanted
	_voice_onnx = ""
	_voice_json = ""
	_cancel_download()
	_resolve_installed_voice()
	if _voice_onnx == "" and _auto_download and not _headless:
		_begin_voice_download()


## Switch voice by "male" or "female", the shorthand the streamer overlay uses.
func set_gender(gender: String) -> void:
	set_voice(String(GENDER_VOICES.get(gender, DEFAULT_VOICE)))


## Where to look for a piper binary. Re-resolves the native backend.
func set_runtime_directory(runtime_dir: String) -> void:
	if runtime_dir == _runtime_dir:
		return
	_runtime_dir = runtime_dir
	_native_bin = RuntimePaths.resolve_executable("piper", _runtime_dir)


func set_enabled(on: bool) -> void:
	_enabled = on
	if on:
		return
	# Ending the current line matters as much as stopping the sound. A listener driving an avatar
	# mouth would otherwise wait forever for a speaking_finished a muted engine never sends.
	_stop_current_line()


## Set this speaker's volume. It moves this engine's own player, not the audio bus. A project
## without the `bus` named in setup() has that player on Master, and turning Master down to quieten
## one voice would take the music and the effects with it.
func set_volume_db(db: float) -> void:
	if _player == null:
		return
	_player.volume_db = db


func is_speaking() -> bool:
	return _busy or _queue.size() > 0


## True once a Piper .onnx for the current voice is on disk.
func has_voice() -> bool:
	return _voice_onnx != ""


## Which backend the next line will use: "native_piper", "python_piper", "system_tts" or "none".
## Probes for python if that has not happened yet, so the first call can block for about 0.14s. It is
## a diagnostic, keep it off per-frame paths. Reached through LocalAgentAgentSpeech.backend_name(),
## and asserted by tests/test_speech_engine.gd.
func backend_name() -> String:
	if _voice_onnx != "":
		if _native_bin != "":
			return "native_piper"
		if python_interpreter() != "":
			return "python_piper"
	if not _headless and not DisplayServer.tts_get_voices().is_empty():
		return "system_tts"
	return "none"


## Queue a line and return. Serialized, and a backlog keeps only the freshest MAX_QUEUE lines so
## commentary stays in sync with what it is describing rather than narrating the distant past.
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


## Synthesize on the calling thread and report whether audio was produced.
##
## True means a wav was written and playback started, or the system voice accepted the line. In
## headless there is no audio device, so it reports whether the wav was written. False means nothing
## could speak, and the reason is pushed as a warning once per engine.
##
## This blocks for a whole piper invocation, interpreter start and model load included. Use speak()
## on any per-frame path.
##
## An explicit speak() outranks queued commentary: this cuts off whatever is speaking and clears the
## backlog before it starts, so the speaker never has two lines going at once.
##
## `opts` accepts `output_path` (absolute) and `voice_id` to override this call only.
func speak_blocking(text: String, opts: Dictionary = {}) -> bool:
	if not _enabled:
		return false
	var line: String = text.strip_edges()
	if line == "":
		return false

	var override_voice: String = String(opts.get("voice_id", ""))
	if override_voice != "" and override_voice != _voice_id:
		set_voice(override_voice)

	# Take the speaker before synthesizing. Without this the queued line's wav lands mid-word on top
	# of this one and the listener sees two speaking_started for one speaking_finished.
	_stop_current_line()

	_ensure_python()
	if _voice_onnx != "" and (_native_bin != "" or _python != ""):
		var out_wav: String = String(opts.get("output_path", ""))
		if out_wav == "":
			out_wav = _next_output_path()
		if _synthesize_to_file(line, out_wav):
			if _headless:
				# No audio device, so the wav is the whole result. Report the beat anyway, so a
				# headless caller sees the same one-started-one-finished pair as a windowed one.
				var gen_headless: int = _begin_line(line)
				_finish_line(gen_headless)
				return true
			if _can_play():
				var gen_wav: int = _begin_line(line)
				if _play_file(out_wav):
					return true
				_finish_line(gen_wav)

	if _speak_os(line):
		var gen_os: int = _begin_line(line)
		_release_after(line, gen_os)
		return true

	_warn_no_backend()
	return false


# --- queued speech --------------------------------------------------------------------------------

func _pump() -> void:
	# _synth_thread guards as hard as _busy does. speak_blocking can end a line while its worker is
	# still running, and starting a second worker there would overwrite the handle of the first,
	# which Godot reports as a thread destroyed while still alive.
	if _busy or _synth_thread != null or _queue.is_empty():
		return
	var line: String = String(_queue.pop_front())

	if _headless:
		# No audio device, and synthesizing every line would cost half a second each in a smoke run.
		# Report the beat instantly so avatar logic still sees the same signals.
		var gen_headless: int = _begin_line(line)
		call_deferred("_finish_line", gen_headless)
		return

	if _voice_onnx != "" and (_native_bin != "" or _resolved_python() != ""):
		var gen_piper: int = _begin_line(line)
		var out_wav: String = _next_output_path()
		_synth_thread = Thread.new()
		_synth_thread.start(Callable(self, "_synthesize_worker").bind(line, out_wav, gen_piper))
		return

	# Piper is not ready yet, the voice may still be downloading. Fall back to the system voice so the
	# speaker is never silent. Piper takes over by itself once the model lands.
	if _speak_os(line):
		var gen_os: int = _begin_line(line)
		_release_after(line, gen_os)
		return

	# Nothing took the line, so there is no beat to start and none to end. Drop it and try the next,
	# rather than emit the bare speaking_finished this used to send with no speaking_started.
	_warn_no_backend()
	_pump()


func _synthesize_worker(line: String, out_wav: String, gen: int) -> void:
	var ok: bool = _synthesize_to_file(line, out_wav)
	call_deferred("_on_synth_done", out_wav if ok else "", gen)


func _on_synth_done(out_wav: String, gen: int) -> void:
	if _synth_thread != null:
		_synth_thread.wait_to_finish()
		_synth_thread = null
	if gen != _generation:
		# speak_blocking or set_enabled(false) took the speaker while this was synthesizing. Drop the
		# wav rather than play it over whatever is talking now.
		_pump()
		return
	if not _enabled or out_wav == "":
		_finish_line(gen)
		return
	if not _play_file(out_wav):
		_finish_line(gen)


func _on_play_finished() -> void:
	_finish_line(_generation)


# Returns the generation this line owns. Every completion path quotes it back, so a callback that
# belongs to a line already cut off does nothing instead of emitting a second speaking_finished.
func _begin_line(line: String) -> int:
	_generation += 1
	_busy = true
	emit_signal("speaking_started", line)
	return _generation


func _finish_line(gen: int) -> void:
	if gen != _generation or not _busy:
		return
	_busy = false
	emit_signal("speaking_finished")
	_pump()


# Stop the speaker and close the current line's beat, so the next line never overlaps it. Bumping
# _generation is what makes the in-flight synthesis and the pending system-voice timer harmless.
func _stop_current_line() -> void:
	_generation += 1
	_queue.clear()
	if _player != null and _player.playing:
		_player.stop()   # stop() emits no finished signal, so the beat is closed by hand below
	if not _headless:
		DisplayServer.tts_stop()
	if _busy:
		_busy = false
		emit_signal("speaking_finished")


# The system voice has no reliable finished signal here, so release the beat after a rough duration.
func _release_after(line: String, gen: int) -> void:
	var secs: float = clampf(float(line.length()) * 0.06, 1.2, 8.0)
	var tree: SceneTree = get_tree()
	if tree == null:
		call_deferred("_finish_line", gen)
		return
	tree.create_timer(secs).timeout.connect(_finish_line.bind(gen), CONNECT_ONE_SHOT)


# --- synthesis ------------------------------------------------------------------------------------

# Runs on the calling thread, which is a worker for speak() and the main thread for speak_blocking().
# Reads only state the main thread set before the call, and writes nothing.
func _synthesize_to_file(line: String, out_wav: String) -> bool:
	if _voice_onnx == "":
		return false
	if _native_bin != "" and _synthesize_native(line, out_wav):
		return true
	if _python != "" and _synthesize_python(line, out_wav):
		return true
	return false


# The preferred path: the piper binary, driven by the native runtime. Unexercised on a stock
# install, because the addon ships no bin/runtimes directory, so _native_bin is "" and
# _synthesize_to_file never calls this. Every step returns false rather than raising, so a runtime
# that is absent, that has no synthesize_speech, that answers with something other than a dictionary,
# or that reports ok without writing the file, all fall through to the python backend.
func _synthesize_native(line: String, out_wav: String) -> bool:
	if not Engine.has_singleton("AgentRuntime"):
		return false
	var runtime: Object = Engine.get_singleton("AgentRuntime")
	if runtime == null or not runtime.has_method("synthesize_speech"):
		return false
	var request: Dictionary = {
		"text": line,
		"voice_path": _voice_onnx,
		"voice_config": _voice_json,
		"output_path": ProjectSettings.globalize_path(out_wav),
		"runtime_directory": RuntimePaths.normalize_path(_runtime_dir) if _runtime_dir != "" else "",
	}
	var response: Variant = runtime.call("synthesize_speech", request)
	if typeof(response) != TYPE_DICTIONARY:
		return false
	if not bool((response as Dictionary).get("ok", false)):
		return false
	# Believe the file, not the flag. This path has never run here, so an ok that wrote nothing has
	# to degrade to the next backend rather than hand the caller a wav that is not there.
	return FileAccess.file_exists(ProjectSettings.globalize_path(out_wav))


# The path a stock install actually uses. Piper reads the line from a file because OS.execute cannot
# pipe stdin.
func _synthesize_python(line: String, out_wav: String) -> bool:
	var txt_path: String = out_wav.get_basename() + ".txt"
	var f: FileAccess = FileAccess.open(txt_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(line)
	f.close()

	var args: PackedStringArray = PackedStringArray([
		"-m", "piper",
		"-m", _voice_onnx,
		"-f", ProjectSettings.globalize_path(out_wav),
		"-i", ProjectSettings.globalize_path(txt_path),
	])
	if _voice_json != "":
		args.append("-c")
		args.append(_voice_json)

	var output: Array = []
	var code: int = OS.execute(_python, args, output, true)
	return code == 0 and FileAccess.file_exists(ProjectSettings.globalize_path(out_wav))


# --- playback -------------------------------------------------------------------------------------

# A player outside the tree refuses to play and only logs an engine error, so asking first is what
# keeps speak_blocking's return value honest.
func _can_play() -> bool:
	return _player != null and _player.is_inside_tree()


func _play_file(out_wav: String) -> bool:
	if not _can_play():
		return false
	var stream: AudioStreamWAV = _load_wav(out_wav)
	if stream == null:
		return false
	if _player.playing:
		_player.stop()
	_player.stream = stream
	_player.play()   # _on_play_finished releases the beat
	return true


func _load_wav(path: String) -> AudioStreamWAV:
	# Godot 4.4+ parses a runtime .wav directly, no import step. ResourceLoader.load cannot: a file
	# written at runtime under user:// has no .import sidecar.
	var stream: Variant = AudioStreamWAV.load_from_file(ProjectSettings.globalize_path(path))
	if stream is AudioStreamWAV:
		return stream as AudioStreamWAV
	return null


# Rotate through a few names so a wav still being read is never the one being written. The prefix is
# this engine's alone, so an agent and the streamer speaking at once cannot collide either.
func _next_output_path() -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TTS_OUT_DIR))
	var path: String = "%s/%s_%d.wav" % [TTS_OUT_DIR, _out_prefix, _out_slot]
	_out_slot = (_out_slot + 1) % OUT_SLOTS
	return path


# --- system voice ---------------------------------------------------------------------------------

func _speak_os(line: String) -> bool:
	if _headless:
		return false
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


# --- python resolution ----------------------------------------------------------------------------

## Which interpreter can `import piper`, or "" when none can. Probes once per process, then answers
## from cache. Blocks for about 0.14s on the first call, so a status probe should call it off any
## per-frame path.
static func python_interpreter() -> String:
	if _python_cache_valid:
		return _python_cache
	_python_cache = _probe_python_now()
	_python_cache_valid = true
	return _python_cache


## True when anything at all can speak: a piper binary in `runtime_dir`, the piper Python module, or
## a system voice. This is the question a status probe wants answered, rather than "is the native
## binary present", which is false on every stock install.
##
## `runtime/AgentStatus.gd._speech_ok()` delegates here, so the setup report and this agree.
##
## The python branch is WORKING-DIRECTORY DEPENDENT: pyenv picks the interpreter from a
## `.python-version` file, so `python3` launched from a project that has one can import piper while the
## same command elsewhere cannot. A false answer there is the environment, not a bug here.
static func speech_available(runtime_dir: String = "") -> bool:
	if RuntimePaths.resolve_executable("piper", runtime_dir) != "":
		return true
	if python_interpreter() != "":
		return true
	if DisplayServer.get_name() == "headless":
		return false
	return not DisplayServer.tts_get_voices().is_empty()


static func _probe_python_now() -> String:
	for cand in PYTHON_CANDIDATES:
		var output: Array = []
		var code: int = OS.execute(String(cand), PackedStringArray(["-c", "import piper"]), output, true)
		if code == 0:
			return String(cand)
	return ""


# Probe off the main thread so scene start never blocks on process spawns.
func _start_python_probe() -> void:
	if _python_probed or _probe_thread != null:
		return
	if _python_cache_valid:
		_python = _python_cache
		_python_probed = true
		return
	_probe_thread = Thread.new()
	_probe_thread.start(Callable(self, "_probe_python"))


func _probe_python() -> void:
	_probe_result = _probe_python_now()
	call_deferred("_join_probe")


# Both callers run on the main thread, so there is no race between them, and wait_to_finish is the
# barrier that makes _probe_result safe to read.
func _join_probe() -> void:
	if _probe_thread == null:
		return
	if _probe_thread.is_started():
		_probe_thread.wait_to_finish()
	_probe_thread = null
	_python = _probe_result
	_python_probed = true
	_python_cache = _python
	_python_cache_valid = true


# Blocking: for speak_blocking, which promised to have tried everything before it returns false.
func _ensure_python() -> void:
	if _probe_thread != null:
		_join_probe()
		return
	if _python_probed:
		return
	_python = python_interpreter()
	_python_probed = true


# Non-blocking: what the queued path knows right now. Adopts a result another engine already probed,
# so the second LocalAgent in a scene does not spend its first line on the system voice.
func _resolved_python() -> String:
	if _python == "" and _python_cache_valid:
		_python = _python_cache
		_python_probed = true
	return _python


# --- voice model ----------------------------------------------------------------------------------

func _requested_voice(options: Dictionary) -> String:
	var requested: String = String(options.get("voice_id", "")).strip_edges()
	if requested == "" and options.has("gender"):
		requested = String(GENDER_VOICES.get(String(options["gender"]), DEFAULT_VOICE))
	return requested if requested != "" else DEFAULT_VOICE


# Prefer a previously downloaded copy under user://, then whatever RuntimePaths can find: a checked
# in voice under res://addons/local_agents/voices, or a path the caller gave outright.
func _resolve_installed_voice() -> void:
	var user_onnx: String = ProjectSettings.globalize_path("%s/%s.onnx" % [VOICE_USER_DIR, _voice_id])
	if FileAccess.file_exists(user_onnx):
		_voice_onnx = user_onnx
		var user_json: String = user_onnx + ".json"
		_voice_json = user_json if FileAccess.file_exists(user_json) else ""
		return
	var assets: Dictionary = RuntimePaths.resolve_voice_assets(_voice_id)
	if assets.is_empty():
		return
	_voice_onnx = String(assets.get("model", ""))
	_voice_json = String(assets.get("config", ""))


# A Piper voice id maps straight onto the repository layout: en_US-ryan-medium lives at
# en/en_US/ryan/medium. An id that does not split that way cannot be downloaded, only installed.
func _voice_url_base() -> String:
	var parts: PackedStringArray = _voice_id.split("-", false)
	if parts.size() != 3:
		return ""
	var locale: String = parts[0]
	if not locale.contains("_"):
		return ""
	var language: String = locale.split("_")[0]
	return "%s/%s/%s/%s/%s" % [VOICE_REPO, language, locale, parts[1], parts[2]]


func _begin_voice_download() -> void:
	var url_base: String = _voice_url_base()
	if url_base == "":
		print("Local Agents: cannot derive a download URL for voice '%s'. Use a full Piper voice id such as en_US-amy-medium, or put the .onnx in %s." % [_voice_id, VOICE_USER_DIR])
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(VOICE_USER_DIR))
	_dl_onnx_path = "%s/%s.onnx" % [VOICE_USER_DIR, _voice_id]
	_dl_json_path = "%s/%s.onnx.json" % [VOICE_USER_DIR, _voice_id]
	_dl_http = HTTPRequest.new()
	add_child(_dl_http)
	_dl_http.request_completed.connect(_on_download_completed)
	# The small config first, then the model itself.
	_dl_stage = "json"
	_dl_http.download_file = ProjectSettings.globalize_path(_dl_json_path)
	var err: int = _dl_http.request("%s/%s.onnx.json" % [url_base, _voice_id])
	if err != OK:
		_dl_stage = "failed"
		return
	print("Local Agents: downloading Piper voice %s to %s, about 63 MB. Lines spoken before it lands use the system voice." % [_voice_id, VOICE_USER_DIR])


func _on_download_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	var ok: bool = result == HTTPRequest.RESULT_SUCCESS and response_code >= 200 and response_code < 300
	if not ok:
		_dl_stage = "failed"
		push_warning("Local Agents could not download the Piper voice %s (result %d, HTTP %d). Speech falls back to the system voice." % [_voice_id, result, response_code])
		return
	if _dl_stage == "json":
		_dl_stage = "onnx"
		_dl_http.download_file = ProjectSettings.globalize_path(_dl_onnx_path)
		var err: int = _dl_http.request("%s/%s.onnx" % [_voice_url_base(), _voice_id])
		if err != OK:
			_dl_stage = "failed"
		return
	if _dl_stage == "onnx":
		_dl_stage = "done"
		_voice_json = ProjectSettings.globalize_path(_dl_json_path)
		_voice_onnx = ProjectSettings.globalize_path(_dl_onnx_path)   # from here on, Piper speaks
		_cancel_download()


func _cancel_download() -> void:
	if _dl_http != null and is_instance_valid(_dl_http):
		_dl_http.queue_free()
	_dl_http = null
	if _dl_stage != "done":
		_dl_stage = ""


# --- diagnostics ----------------------------------------------------------------------------------

# One warning per engine, not one per line: a speaker with no backend would otherwise fill the log.
func _warn_no_backend() -> void:
	if _warned:
		return
	_warned = true
	var reasons: PackedStringArray = PackedStringArray()
	if _voice_onnx == "":
		reasons.append("no Piper voice model for '%s' under %s" % [_voice_id, VOICE_USER_DIR])
	if _native_bin == "":
		reasons.append("no piper binary in the runtime directory")
	if _python == "" and _python_probed:
		reasons.append("no python on PATH that can import piper")
	if _headless:
		reasons.append("the display server is headless, so there is no system voice")
	elif DisplayServer.tts_get_voices().is_empty():
		reasons.append("no system voice is installed")
	# One reason per line. Joining them with commas ran the last one, which has a clause of its own,
	# straight into the sentence before it.
	var message: String = "Local Agents cannot speak:"
	for reason in reasons:
		message += "\n  - %s" % reason
	message += "\nInstall the Python module with 'pip install piper-tts', or put a piper binary in the runtime directory."
	push_warning(message)
