@tool
extends RefCounted

## Headless self-check for the speech path, so a regression in LocalAgent.speak() is visible without a
## windowed run and without a person listening.
##
## Run it with:
##
##     scripts/run_single_test.sh test_speech_engine.gd --timeout=60
##
## Three things are asserted on every machine, because they need no backend at all:
##
## 1. two engines in one process never hand out the same output wav (an agent and the streamer each
##    own one),
## 2. an explicit speak() while a queued line is in flight still leaves exactly one speaking_finished
##    per speaking_started,
## 3. backend_name() answers with one of its four documented values, and LocalAgentAgentSpeech
##    reports the same one.
##
## The fourth, that speak_blocking actually writes a wav, needs a Piper voice model and either a piper
## binary or a Python interpreter that can import piper. When neither is present the check prints the
## reason and passes, so a machine with no piper install does not fail the build.
##
## The run is headless, so nothing is audible and nothing is played. What it proves is that a wav was
## written and that the signal contract held.
##
## run_single_test.gd calls run_test synchronously, so this file never awaits a frame. Where the
## engine would finish a line on a deferred call, the check invokes that call itself with the same
## argument the engine deferred, which is the point of the assertion anyway: a completion belonging
## to a line that was already cut off has to do nothing.
##
## (Explicit types only, project rule: no ':=' inferred typing.)

const SpeechEngineScript: GDScript = preload("res://addons/local_agents/runtime/audio/SpeechEngine.gd")
const AgentSpeechScript: GDScript = preload("res://addons/local_agents/agents/AgentSpeech.gd")

const TTS_DIR: String = "user://local_agents/tts"
const PROBE_WAV: String = "user://local_agents/tts/selfcheck.wav"
const PROBE_TXT: String = "user://local_agents/tts/selfcheck.txt"
const QUEUED_LINE: String = "Queued line alpha, which the blocking line takes over."
const BLOCKING_LINE: String = "Blocking line bravo, which owns the speaker."
const MIN_WAV_BYTES: int = 1024

var _started: int = 0
var _finished: int = 0


func run_test(tree: SceneTree) -> bool:
	var ok: bool = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TTS_DIR))

	var engine_a: SpeechEngineScript = SpeechEngineScript.new()
	engine_a.name = "SpeechSelfCheckA"
	tree.root.add_child(engine_a)
	engine_a.setup({"voice_id": "en_US-ryan-medium", "auto_download": false})

	var engine_b: SpeechEngineScript = SpeechEngineScript.new()
	engine_b.name = "SpeechSelfCheckB"
	tree.root.add_child(engine_b)
	engine_b.setup({"gender": "female", "auto_download": false})

	# 1. Output paths. Both engines rotate their own slot counter, so the sequences have to be
	# disjoint. They were identical when the slot was the only thing in the file name.
	var paths_a: Array[String] = []
	var paths_b: Array[String] = []
	for _index in range(3):
		paths_a.append(engine_a._next_output_path())
		paths_b.append(engine_b._next_output_path())
	var paths_unique: bool = true
	for path in paths_a:
		if paths_b.has(path):
			paths_unique = false
	if not paths_unique:
		push_error("Speech self-check: two engines share an output path. A=%s B=%s" % [paths_a, paths_b])
	ok = ok and paths_unique

	# 2. Backend report, and the LocalAgentAgentSpeech wrapper that reaches it.
	var backend: String = engine_a.backend_name()
	var known: Array[String] = ["native_piper", "python_piper", "system_tts", "none"]
	if not known.has(backend):
		push_error("Speech self-check: backend_name() answered '%s', which is not one of %s" % [backend, known])
	ok = ok and known.has(backend)

	var host: Node = Node.new()
	host.name = "SpeechSelfCheckHost"
	tree.root.add_child(host)
	var speech: AgentSpeechScript = AgentSpeechScript.new()
	speech.attach(host)
	var wrapper_backend: String = speech.backend_name("", "")
	if wrapper_backend != backend:
		push_error("Speech self-check: the agent wrapper reports '%s' where the engine reports '%s'" % [wrapper_backend, backend])
	ok = ok and wrapper_backend == backend

	# 3. One speaking_finished per speaking_started, even when speak_blocking cuts a queued line off.
	# With no backend installed the speak_blocking below pushes the "cannot speak" warning, which is
	# the engine working as designed and not a failure of this check.
	engine_a.speaking_started.connect(_on_started)
	engine_a.speaking_finished.connect(_on_finished)
	engine_a.speak(QUEUED_LINE)
	var queued_generation: int = engine_a._generation
	var started_ms: int = Time.get_ticks_msec()
	var said: bool = engine_a.speak_blocking(BLOCKING_LINE, {"output_path": PROBE_WAV})
	var say_ms: int = Time.get_ticks_msec() - started_ms
	# The queued line ends on call_deferred("_finish_line", <its generation>). Make that call by hand,
	# with the generation the engine deferred, to prove it is inert now that speak_blocking took over.
	# Left to a real frame it would land after this function has returned.
	engine_a._finish_line(queued_generation)
	var balanced: bool = _started >= 1 and _started == _finished
	if not balanced:
		push_error("Speech self-check: %d speaking_started against %d speaking_finished" % [_started, _finished])
	ok = ok and balanced

	# 4. The part that needs a backend.
	var wav_bytes: int = 0
	var skip_reason: String = ""
	if backend == "python_piper" or backend == "native_piper":
		wav_bytes = _file_size(PROBE_WAV)
		if not said:
			push_error("Speech self-check: speak_blocking returned false with backend '%s' available" % backend)
		ok = ok and said
		if wav_bytes < MIN_WAV_BYTES:
			push_error("Speech self-check: %s is %d bytes, expected at least %d" % [PROBE_WAV, wav_bytes, MIN_WAV_BYTES])
		ok = ok and wav_bytes >= MIN_WAV_BYTES
	else:
		skip_reason = _skip_reason(engine_a)
		print("Speech self-check: synthesis not exercised, %s" % skip_reason)

	print("SPEECH_SELFCHECK=%s" % JSON.stringify({
		"backend": backend,
		"wrapper_backend": wrapper_backend,
		"available": SpeechEngineScript.speech_available(),
		"paths_unique": paths_unique,
		"first_path_a": paths_a[0],
		"first_path_b": paths_b[0],
		"started": _started,
		"finished": _finished,
		"balanced": balanced,
		"said": said,
		"wav_bytes": wav_bytes,
		"say_ms": say_ms,
		"skipped": skip_reason,
	}))

	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROBE_WAV))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROBE_TXT))
	# free(), not queue_free(): the runner quits without another frame, so a queued free never runs.
	engine_a.free()
	engine_b.free()
	host.free()

	if ok:
		print("Local Agents speech self-check passed")
	else:
		push_error("Speech self-check assertions failed")
	return ok


func _on_started(_text: String) -> void:
	_started += 1


func _on_finished() -> void:
	_finished += 1


# Why synthesis could not be exercised here, in the same terms the engine's own warning uses.
func _skip_reason(engine: SpeechEngineScript) -> String:
	if not engine.has_voice():
		return "there is no Piper voice model for the default voice under %s" % SpeechEngineScript.VOICE_USER_DIR
	if SpeechEngineScript.python_interpreter() == "":
		return "no python on PATH can import piper, and the addon ships no piper binary"
	return "no speech backend is available in this environment"


func _file_size(path: String) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var handle: FileAccess = FileAccess.open(path, FileAccess.READ)
	if handle == null:
		return 0
	var size: int = int(handle.get_length())
	handle.close()
	return size
