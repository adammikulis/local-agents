class_name LAStreamerDirector
extends Node

## The commentator's brain. Watches the living sim, decides WHEN there is something worth saying, and
## turns it into one short streamer line via a local llama-server — all off the physics frame. It never
## blocks: server bring-up runs on a worker thread, and every generation is an async HTTPRequest with a
## single-in-flight budget (mirroring cognition/CognitionScheduler). If the server is not up yet it
## falls back to canned streamer-isms so the stream is never dead.
##
## Context hygiene: the request is near-stateless — a persona system prompt + only a short rolling
## window of recent lines + the current scene delta — and the window is hard-reset on big events / every
## N lines, so the model never accumulates context rot.
##
## Emits `line_ready(text)`; the world wires that to the overlay caption + StreamerVoice.
## (Explicit types only — project rule: no ':=' inferred typing.)

const RuntimePaths: GDScript = preload("res://addons/local_agents/runtime/RuntimePaths.gd")
const LlamaServerManager: GDScript = preload("res://addons/local_agents/runtime/LlamaServerManager.gd")

signal line_ready(text: String)
signal status_changed(status: String)

# Species → friendly plural for the scene snapshot.
const SPECIES_LABELS: Dictionary = {
	"fox": "foxes", "rabbit": "rabbits", "bird": "birds", "vulture": "vultures",
	"villager": "villagers", "fish": "fish", "plant": "plants",
}

const CANNED_FILLERS: Array = [
	"Chat, if you're vibing with the ecosystem, smash that like button!",
	"Don't forget to hit follow so you never miss a meteor, chat!",
	"We are SO back. Look at this beautiful little food web go.",
	"Shoutout to everyone in chat keeping the wildlife company tonight.",
	"Quiet moment on the savanna... perfect time to subscribe, honestly.",
	"Nature's just built different, chat. Absolutely cracked biome.",
	"Stay hydrated like these little guys are trying to, chat.",
]
const CANNED_REACTIONS: Array = [
	"Ohhh it's going DOWN out there!",
	"Chat did you SEE that?!",
	"No shot, no shot, NO SHOT!",
	"The circle of life is not messing around today.",
]

var _world: Node = null
var _voice: Node = null                # optional; checked for is_speaking()
var _enabled: bool = true

# --- llama-server ---
var _server_mgr = null
var _server_url: String = "http://127.0.0.1:8080"
var _server_ready: bool = false
var _server_thread: Thread = null
var _model_path: String = ""
var _model_name: String = "local"

# --- persona / context hygiene ---
var _persona_id: String = ""
var _window: Array = []                # recent assistant lines: [{role,content}]
const WINDOW_MAX: int = 4
var _lines_since_reset: int = 0
const RESET_EVERY: int = 12

# --- pacing: event-intensity scanner ---
# The caster does NOT talk on a timer. Every detected event carries an intensity weight; those weights
# accumulate and DECAY over time. A line only fires when the running intensity trips THRESHOLD (so a
# volcano or a death sets it off, but a calm biome stays quiet), gated by a minimum cooldown so even a
# chaotic stretch doesn't machine-gun lines. A long idle filler keeps the stream from going fully dead.
const SAMPLE_INTERVAL: float = 0.5
const INTENSITY_THRESHOLD: float = 6.0
const INTENSITY_DECAY: float = 0.8      # points bled off per second, so stale minor events fade out
const MIN_COOLDOWN: float = 6.0         # never two lines closer than this
const IDLE_FILLER: float = 45.0         # if nothing trips for this long, drop one hype filler
var _sample_accum: float = 0.0
var _intensity: float = 0.0
var _time_since_line: float = 0.0
var _pending_request: bool = false

# --- scene sampling ---
var _last_sample: Dictionary = {}
var _events: Array = []                # accumulated {text, urgent} since the last line
var _last_tod_phase: String = ""
var _last_line: String = ""            # exposed for smoke output


func setup(world: Node, options: Dictionary = {}) -> void:
	_world = world
	_voice = options.get("voice", null)
	_enabled = bool(options.get("enabled", true))
	_persona_id = String(options.get("persona", LAStreamerPersonas.default_id()))
	_server_url = String(options.get("server_url", "http://127.0.0.1:8080")).strip_edges()
	while _server_url.ends_with("/"):
		_server_url = _server_url.substr(0, _server_url.length() - 1)
	_model_path = _resolve_model_path(String(options.get("model_path", "")))
	_model_name = _model_path.get_file() if _model_path != "" else "local"

	# Headless smoke runs stay light and fast: prove event-detection + line emission with canned lines,
	# without loading a 1GB model each run. The real llama-server only boots in a windowed session.
	var headless: bool = DisplayServer.get_name() == "headless"
	if _model_path != "" and not headless:
		_server_thread = Thread.new()
		_server_thread.start(Callable(self, "_boot_server"))
		emit_signal("status_changed", "starting model…")
	elif headless:
		emit_signal("status_changed", "headless — canned mode")
	else:
		emit_signal("status_changed", "no model — canned mode")


func set_enabled(on: bool) -> void:
	_enabled = on


func set_persona(id: String) -> void:
	_persona_id = id
	_reset_window()   # switching voice: drop stale continuity so the new persona starts clean


func latest_line() -> String:
	return _last_line


# --- server bring-up (worker thread) ------------------------------------------------------------

func _boot_server() -> void:
	var mgr = LlamaServerManager.new()
	var runtime_dir: String = RuntimePaths.runtime_dir()
	var opts: Dictionary = {
		"server_base_url": _server_url,
		"context_size": 4096,
		"n_gpu_layers": 99,
		"server_slots": 1,
		"server_start_timeout_ms": 40000,
	}
	var result: Dictionary = mgr.ensure_running(opts, _model_path, runtime_dir)
	call_deferred("_on_server_booted", mgr, result)


func _on_server_booted(mgr, result: Dictionary) -> void:
	if _server_thread != null:
		_server_thread.wait_to_finish()
		_server_thread = null
	_server_mgr = mgr
	_server_ready = bool(result.get("ok", false))
	if _server_ready:
		emit_signal("status_changed", "live: %s" % _model_name)
	else:
		emit_signal("status_changed", "server offline — canned mode (%s)" % String(result.get("error", "?")))


func _resolve_model_path(preferred: String) -> String:
	var candidates: Array = []
	if preferred != "":
		candidates.append(preferred)
	# Default to the ~2B tier (Qwen3-1.7B); degrade to 0.6B, then the 4B res copy if present.
	candidates.append("user://local_agents/models/qwen3-1_7b/Qwen3-1.7B-Q4_K_M.gguf")
	candidates.append("user://local_agents/models/qwen3-0_6b-instruct/Qwen3-0.6B-Q4_K_M.gguf")
	candidates.append("user://local_agents/models/qwen3-4b-instruct/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")
	for c in candidates:
		if FileAccess.file_exists(ProjectSettings.globalize_path(String(c))):
			return String(c)
	return ""


# --- main loop ----------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _enabled or _world == null:
		return

	_sample_accum += delta
	if _sample_accum >= SAMPLE_INTERVAL:
		_sample_accum = 0.0
		_take_sample()

	# Bleed off intensity so an occasional small event never slowly sums its way to a comment.
	_intensity = maxf(0.0, _intensity - INTENSITY_DECAY * delta)
	_time_since_line += delta

	if _pending_request or _voice_busy() or _time_since_line < MIN_COOLDOWN:
		return
	if _intensity >= INTENSITY_THRESHOLD:
		_fire(false)   # something worth reacting to just happened
	elif _time_since_line >= IDLE_FILLER:
		_fire(true)    # long quiet stretch — one filler to keep the stream alive


func _voice_busy() -> bool:
	return _voice != null and _voice.has_method("is_speaking") and bool(_voice.is_speaking())


# --- scene sampling / event detection -----------------------------------------------------------

func _take_sample() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var species_counts: Dictionary = {}
	var states: Dictionary = {}
	var pop: int = 0
	for n in tree.get_nodes_in_group("creature"):
		if not is_instance_valid(n):
			continue
		pop += 1
		var sp: String = String(n.get("species"))
		species_counts[sp] = int(species_counts.get(sp, 0)) + 1
		var st: String = String(n.get("state"))
		states[st] = int(states.get(st, 0)) + 1
	var corpses: int = tree.get_nodes_in_group("carrion").size()
	var destruction: float = float(_world.get("_music_destruction")) if _world.get("_music_destruction") != null else 0.0
	var tod: float = float(_world.get("_time_of_day")) if _world.get("_time_of_day") != null else 0.5
	var fires: int = _fire_count()

	var sample: Dictionary = {
		"pop": pop, "species": species_counts, "states": states,
		"corpses": corpses, "destruction": destruction, "tod": tod, "fires": fires,
	}
	if not _last_sample.is_empty():
		_detect_events(_last_sample, sample)
	_last_sample = sample


# Intensity weights: the scanner's "how big a deal is this" score. THRESHOLD is 6, so anything >=6
# fires on its own; smaller events must stack (and beat the decay) to trip a line.
const I_DISASTER: float = 12.0   # meteor / volcano / earthquake / flood / lightning impact
const I_EXTINCT: float = 10.0
const I_FIRE: float = 7.0
const I_DEATH: float = 6.0        # a single death trips; +2 per extra death in the same tick
const I_STAMPEDE: float = 6.0
const I_CHASE: float = 3.0
const I_STALK: float = 3.0
const I_CIRCLE: float = 2.0
const I_BIRTH: float = 1.0
const I_DAYNIGHT: float = 1.0


func _detect_events(prev: Dictionary, cur: Dictionary) -> void:
	# Disaster: a fresh destruction spike (edge-triggered). Every disaster in VoxelWorld._apply_at
	# (meteor, volcano, lightning, earthquake, flood) spikes _music_destruction, so this catches them all.
	if float(cur.get("destruction", 0.0)) > 0.75 and float(prev.get("destruction", 0.0)) <= 0.75:
		_push_event("a violent natural disaster just struck — the ground is in chaos and animals are scattering", I_DISASTER)
		_reset_window()   # mood pivot: forget the calm chatter that came before
	# Fires starting.
	if int(cur.get("fires", 0)) > int(prev.get("fires", 0)) and int(prev.get("fires", 0)) == 0:
		_push_event("a fire has broken out and is spreading", I_FIRE)

	# Deaths (population down and/or fresh corpses).
	var dpop: int = int(prev.get("pop", 0)) - int(cur.get("pop", 0))
	var dcorpse: int = int(cur.get("corpses", 0)) - int(prev.get("corpses", 0))
	if dcorpse > 0 or dpop > 0:
		var n_dead: int = maxi(dcorpse, dpop)
		_push_event("%d animal%s just died" % [n_dead, "s" if n_dead != 1 else ""], I_DEATH + float(n_dead - 1) * 2.0)
	# Births.
	var births: int = int(cur.get("pop", 0)) - int(prev.get("pop", 0))
	if births > 0:
		_push_event("%d new animal%s just born" % [births, "s" if births != 1 else ""], I_BIRTH)

	# Per-species extinction.
	var prev_sp: Dictionary = prev.get("species", {})
	var cur_sp: Dictionary = cur.get("species", {})
	for sp in prev_sp:
		if int(prev_sp[sp]) > 0 and int(cur_sp.get(sp, 0)) == 0:
			_push_event("the last %s has died out" % _species_label(String(sp)), I_EXTINCT)

	# Behaviour spikes (predation, scavenging, fear).
	_behaviour_delta(prev.get("states", {}), cur.get("states", {}), "stalk", "a predator has started stalking prey", I_STALK)
	_behaviour_delta(prev.get("states", {}), cur.get("states", {}), "chase", "a chase is on — predator closing on prey", I_CHASE)
	_behaviour_delta(prev.get("states", {}), cur.get("states", {}), "circle", "vultures are circling a carcass", I_CIRCLE)
	_behaviour_delta(prev.get("states", {}), cur.get("states", {}), "panic", "the herd has broken into a terrified stampede", I_STAMPEDE)

	# Day/night transition.
	var phase: String = _tod_phase(float(cur.get("tod", 0.5)))
	if phase != _last_tod_phase and _last_tod_phase != "":
		_push_event("%s" % phase, I_DAYNIGHT)
	_last_tod_phase = phase


func _behaviour_delta(prev_states: Dictionary, cur_states: Dictionary, key: String, text: String, intensity: float) -> void:
	if int(cur_states.get(key, 0)) > int(prev_states.get(key, 0)) and int(prev_states.get(key, 0)) == 0:
		_push_event(text, intensity)


func _push_event(text: String, intensity: float) -> void:
	_events.append({"text": text, "intensity": intensity})
	_intensity += intensity   # feed the scanner
	while _events.size() > 8:
		_events.pop_front()


func _tod_phase(tod: float) -> String:
	if tod >= 0.23 and tod < 0.27:
		return "dawn is breaking"
	if tod >= 0.73 and tod < 0.77:
		return "night is falling"
	return "day" if (tod >= 0.25 and tod < 0.75) else "night"


# --- firing a line ------------------------------------------------------------------------------

func _fire(idle: bool) -> void:
	_intensity = 0.0
	_time_since_line = 0.0
	var events_snapshot: Array = _events.duplicate()
	_events.clear()

	# Idle filler is intentionally cheap + rare: a canned hype line, no model call.
	if idle:
		_emit_line(_canned([]))
		return
	if not _server_ready:
		# No brain yet: keep the energy up with a canned reaction.
		_emit_line(_canned(events_snapshot))
		return
	_dispatch_llm(events_snapshot)


func _dispatch_llm(events_snapshot: Array) -> void:
	var http: HTTPRequest = HTTPRequest.new()
	add_child(http)
	http.timeout = 8.0
	http.request_completed.connect(_on_llm_completed.bind(http, events_snapshot))

	var messages: Array = [{"role": "system", "content": LAStreamerPersonas.system_prompt(_persona_id) + " /no_think"}]
	messages.append_array(_window)
	messages.append({"role": "user", "content": _build_context(events_snapshot)})

	var body: Dictionary = {
		"model": _model_name,
		"messages": messages,
		"temperature": 0.9,
		"top_p": 0.9,
		"frequency_penalty": 0.7,
		"presence_penalty": 0.5,
		"max_tokens": 64,
		"stream": false,
	}
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	var err: int = http.request(_server_url + "/v1/chat/completions", headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		http.queue_free()
		_emit_line(_canned(events_snapshot))
		return
	_pending_request = true


func _on_llm_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest, events_snapshot: Array) -> void:
	if is_instance_valid(http):
		http.queue_free()
	_pending_request = false
	var line: String = ""
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if parsed is Dictionary:
			line = _clean(_extract_content(parsed as Dictionary))
	# Reject a repeat of anything said recently (the small model latches onto a phrase) — fall back to a
	# varied canned reaction rather than saying the same thing twice.
	if line != "" and _said_recently(line):
		line = ""
	if line == "":
		line = _canned(events_snapshot)
	else:
		# Only real model lines feed the rolling window (keeps continuity, bounded).
		_window.append({"role": "assistant", "content": line})
		while _window.size() > WINDOW_MAX:
			_window.pop_front()
		_lines_since_reset += 1
		if _lines_since_reset >= RESET_EVERY:
			_reset_window()
	_emit_line(line)


func _emit_line(text: String) -> void:
	if text == "":
		return
	_last_line = text
	emit_signal("line_ready", text)


func _build_context(events_snapshot: Array) -> String:
	# Keep this terse and NON-recitable: hand the model the dramatic beats + a mood word, not a stat
	# dump it can parrot. Numbers/species tallies were being read out verbatim, so they are omitted.
	var snap: Dictionary = _last_sample
	var mood: PackedStringArray = PackedStringArray()
	mood.append(_tod_phase(float(snap.get("tod", 0.5))))
	if int(snap.get("fires", 0)) > 0:
		mood.append("wildfire in the air")

	var ev: PackedStringArray = PackedStringArray()
	for e in events_snapshot:
		ev.append(String((e as Dictionary).get("text", "")))
	var beats: String = "; ".join(ev) if ev.size() > 0 else "a brief lull"

	return ("Mood: %s. What just happened out there: %s.\n"
		+ "Give your ONE reaction line now — react, do not describe or recite, do not repeat yourself.") % [", ".join(mood), beats]


# --- helpers ------------------------------------------------------------------------------------

func _reset_window() -> void:
	_window.clear()
	_lines_since_reset = 0


## Has this exact line been said within the recent rolling window (or as the immediately previous line)?
func _said_recently(line: String) -> bool:
	if line == _last_line:
		return true
	for w in _window:
		if String((w as Dictionary).get("content", "")) == line:
			return true
	return false


func _extract_content(response: Dictionary) -> String:
	var choices = response.get("choices", [])
	if not (choices is Array) or (choices as Array).is_empty():
		return ""
	var first = (choices as Array)[0]
	if not (first is Dictionary):
		return ""
	var message = (first as Dictionary).get("message", {})
	if not (message is Dictionary):
		return ""
	return String((message as Dictionary).get("content", ""))


## Sanitize a raw model completion into one clean spoken line: drop any <think> block, strip
## markup/quotes, collapse to a single line, and cap the length.
func _clean(raw: String) -> String:
	var text: String = raw
	var think_end: int = text.find("</think>")
	if think_end != -1:
		text = text.substr(think_end + 8)
	text = text.replace("\r", "\n")
	var nl: int = text.find("\n")
	while nl != -1:
		# keep the first non-empty line
		var head: String = text.substr(0, nl).strip_edges()
		if head != "":
			text = head
			break
		text = text.substr(nl + 1)
		nl = text.find("\n")
	text = text.strip_edges()
	for ch in ["*", "\"", "`", "#", "_"]:
		text = text.replace(ch, "")
	if text.begins_with("- "):
		text = text.substr(2)
	if text.length() > 200:
		text = text.substr(0, 200).strip_edges() + "…"
	return text


func _canned(events_snapshot: Array) -> String:
	# Reaction line when something happened, otherwise a hype filler. Index varies with frame count so
	# it doesn't repeat identically (Math.random is unavailable in some contexts; frame is fine here).
	var idx: int = Engine.get_process_frames()
	if events_snapshot.size() > 0:
		return String(CANNED_REACTIONS[idx % CANNED_REACTIONS.size()])
	return String(CANNED_FILLERS[idx % CANNED_FILLERS.size()])


func _fire_count() -> int:
	if _world == null:
		return 0
	if _world.get("_ecology") == null:
		return 0
	var eco = _world.get("_ecology")
	if eco != null and eco.has_method("fire_system"):
		var fs = eco.fire_system()
		if fs != null and fs.has_method("active_fire_count"):
			return int(fs.active_fire_count())
	return 0


func _species_label(sp: String) -> String:
	return String(SPECIES_LABELS.get(sp, sp + "s"))


func _exit_tree() -> void:
	if _server_thread != null:
		_server_thread.wait_to_finish()   # boot may still be in flight on quit
		_server_thread = null
	if _server_mgr != null and _server_mgr.has_method("stop_managed"):
		_server_mgr.stop_managed()
