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

# --- pacing: event-intensity accumulator ---
# The caster does NOT talk on a timer, and it no longer SCANS the world for events itself — the shared
# LAEventTracker is the ONE emergent source, and on_tracked_event() feeds each typed event's intensity in
# here. Those weights accumulate and DECAY over time. A line only fires when the running intensity trips
# THRESHOLD (so a volcano or a death sets it off, but a calm biome stays quiet), gated by a minimum cooldown
# so even a chaotic stretch doesn't machine-gun lines. A long idle filler keeps the stream from going dead.
const SAMPLE_INTERVAL: float = 0.5
const INTENSITY_THRESHOLD: float = 6.0
const INTENSITY_DECAY: float = 0.8      # points bled off per second, so stale minor events fade out
const MIN_COOLDOWN: float = 6.0         # never two lines closer than this
const IDLE_FILLER: float = 45.0         # if nothing trips for this long, drop one hype filler
# URGENT queue: big events (disasters, extinctions, fires, deaths, stampedes) must NEVER slip through
# just because the caster was mid-line or waiting on the LLM when they happened. They are queued here and
# survive the intensity decay — the moment the caster is free (not speaking, not awaiting a reply) it
# pops the queue and reacts, even if the decaying ambient intensity has bled below THRESHOLD. This is the
# "accumulate and pop" fix: ambient chatter uses the decaying score; landmark events use the queue.
const URGENT_BAR: float = 6.0           # an event at/above this intensity is queued as must-say
const URGENT_COOLDOWN: float = 2.5      # urgent events may interrupt the idle gap (but never a live line)
const URGENT_MAX: int = 6               # cap the backlog; keep the most recent landmark beats
var _sample_accum: float = 0.0
var _intensity: float = 0.0
var _time_since_line: float = 0.0
var _pending_request: bool = false
# The scene's total physical energy (kinetic + seismic + thermal) feeds the scanner directly: a RISE in
# energy — a herd breaking into a run, a meteor's impact, a wildfire flaring — pushes intensity, so how
# hard the caster reacts scales with how much actually just happened, not a per-event constant.
const ENERGY_TO_INTENSITY: float = 0.02   # intensity points per unit of energy RISE between samples
const ENERGY_URGENT_RISE: float = 400.0   # an energy jump this big is a landmark — queue a must-say beat
var _energy_source: Node = null           # LASceneEnergyGraph, exposes current_total()
var _last_energy: float = 0.0
var _energy_primed: bool = false         # seed _last_energy on the first sample so the starting energy isn't a false surge

# --- scene sampling ---
# Behaviour states worth naming in the commentary; each carries a representative animal (species,
# location, its prey) so the caster can react to "a fox stalking the rabbits down by the water" rather
# than the old generic "a predator has started stalking prey".
const HOT_STATES: Array = ["stalk", "chase", "circle", "panic"]
var _pop_baseline: float = 0.0         # slow EMA of total population, for the "numbers rising/thinning" narrative
var _last_sample: Dictionary = {}
var _events: Array = []                # accumulated {text, intensity} since the last line (ambient colour)
var _urgent: Array = []                # queued must-say landmark events, immune to decay (see above)
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


## Wire the scene-energy source (LASceneEnergyGraph) so intensity tracks real physical energy.
func set_energy_source(node: Node) -> void:
	_energy_source = node


func latest_line() -> String:
	return _last_line


# --- server bring-up (worker thread) ------------------------------------------------------------

func _boot_server() -> void:
	var mgr = LlamaServerManager.new()
	var runtime_dir: String = RuntimePaths.runtime_dir()
	# GPU layers: the commentator LLM shares the machine's Metal GPU with the game's RENDERER, so offloading
	# all layers (99) means each generation STARVES rendering — measured ~90ms/frame, dropping the sim from
	# ~45 to ~9 FPS. Commentary is occasional, short, and fully async (worker thread + HTTPRequest), so it
	# does NOT need GPU speed: default to CPU inference (0 layers) to keep the render GPU free. Override with
	# env LA_STREAMER_GPU_LAYERS=<n> if you have GPU headroom and want faster commentary.
	var gpu_layers: int = 0
	if OS.has_environment("LA_STREAMER_GPU_LAYERS"):
		gpu_layers = maxi(0, int(OS.get_environment("LA_STREAMER_GPU_LAYERS")))
	var opts: Dictionary = {
		"server_base_url": _server_url,
		"context_size": 4096,
		"n_gpu_layers": gpu_layers,
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

	# Never talk over a live line or a request in flight.
	if _pending_request or _voice_busy():
		return
	# A queued landmark event (volcano, extinction, wildfire...) is spoken the instant the caster frees up
	# — it survived the decay, so it fires even if the ambient intensity has faded. Only a short cooldown
	# gates it (not the full one) so a big moment isn't stale by the time it's mentioned.
	if not _urgent.is_empty() and _time_since_line >= URGENT_COOLDOWN:
		_fire(false)
		return
	if _time_since_line < MIN_COOLDOWN:
		return
	if _intensity >= INTENSITY_THRESHOLD:
		_fire(false)   # ambient chatter tripped the scanner
	elif _time_since_line >= IDLE_FILLER:
		_fire(true)    # long quiet stretch — one filler to keep the stream alive


func _voice_busy() -> bool:
	return _voice != null and _voice.has_method("is_speaking") and bool(_voice.is_speaking())


# --- scene sampling / event detection -----------------------------------------------------------

func _take_sample() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var mat = _world.get("_material") if _world != null else null
	var sea: float = float(mat.sea_level) if mat != null and mat.get("sea_level") != null else 0.0
	var species_counts: Dictionary = {}
	var states: Dictionary = {}
	var species_states: Dictionary = {}   # species -> {state -> count}
	var hot: Dictionary = {}              # "species|state" -> {loc, prey}: one representative per hot beat
	var pop: int = 0
	for n in tree.get_nodes_in_group("creature"):
		if not is_instance_valid(n):
			continue
		pop += 1
		var sp: String = String(n.get("species"))
		species_counts[sp] = int(species_counts.get(sp, 0)) + 1
		var st: String = String(n.get("state"))
		states[st] = int(states.get(st, 0)) + 1
		var ss: Dictionary = species_states.get(sp, {})
		ss[st] = int(ss.get(st, 0)) + 1
		species_states[sp] = ss
		# Snapshot the FIRST animal we see in each hot beat: where it is and (for hunters) what it hunts,
		# so the caster gets concrete, namable detail instead of an anonymous role label.
		var hkey: String = sp + "|" + st
		if HOT_STATES.has(st) and not hot.has(hkey):
			var pos: Vector3 = (n as Node3D).global_position if n is Node3D else Vector3.ZERO
			var near_water: bool = mat != null and mat.has_method("is_water_at") and bool(mat.is_water_at(pos))
			var prey: String = ""
			var po = n.get("preys_on")
			if po is PackedStringArray and (po as PackedStringArray).size() > 0:
				prey = String((po as PackedStringArray)[0])
			hot[hkey] = {"loc": _loc_phrase(near_water, pos.y, sea), "prey": prey}
	var corpses: int = tree.get_nodes_in_group("carrion").size()
	var destruction: float = float(_world.get("_music_destruction")) if _world.get("_music_destruction") != null else 0.0
	var tod: float = float(_world.get("_time_of_day")) if _world.get("_time_of_day") != null else 0.5
	var fires: int = _fire_count()

	# Slow population EMA drives the "their numbers are climbing / thinning out" running-narrative clause.
	_pop_baseline = float(pop) if _pop_baseline <= 0.0 else _pop_baseline * 0.95 + float(pop) * 0.05

	var sample: Dictionary = {
		"pop": pop, "species": species_counts, "states": states,
		"species_states": species_states, "hot": hot,
		"corpses": corpses, "destruction": destruction, "tod": tod, "fires": fires,
		"cloud": _cloud_cover(),
	}
	if not _last_sample.is_empty():
		_detect_events(_last_sample, sample)
	_last_sample = sample

	# Physical energy → intensity. A RISE in total scene energy since the last sample feeds the scanner in
	# proportion to how big it is; a large jump is a landmark event and joins the must-say queue too.
	if _energy_source != null and _energy_source.has_method("current_total"):
		var e: float = float(_energy_source.current_total())
		if not _energy_primed:
			_energy_primed = true       # first sample: seed the baseline so the whole starting energy isn't a phantom "surge"
			_last_energy = e
		else:
			var rise: float = maxf(0.0, e - _last_energy)
			if rise > 0.0:
				_intensity += rise * ENERGY_TO_INTENSITY
				if rise >= ENERGY_URGENT_RISE:
					_push_event("a massive surge of energy just tore through the scene", URGENT_BAR + rise * 0.01)
			_last_energy = e


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


## Creature-NARRATION detection (deaths/births/extinction/behaviour spikes) — the streamer's own rich,
## per-species, located beats. FIELD phenomena (eruption/wildfire/flood/storm/lightning/impact) are NOT
## detected here anymore: they arrive from the shared LAEventTracker via on_tracked_event(), so the crude
## destruction-spike + raw fire-count scans that used to live here are dissolved (no parallel field scans).
func _detect_events(prev: Dictionary, cur: Dictionary) -> void:
	var prev_sp: Dictionary = prev.get("species", {})
	var cur_sp: Dictionary = cur.get("species", {})

	# Deaths (population down and/or fresh corpses) — named by the species that actually lost members.
	var dpop: int = int(prev.get("pop", 0)) - int(cur.get("pop", 0))
	var dcorpse: int = int(cur.get("corpses", 0)) - int(prev.get("corpses", 0))
	if dcorpse > 0 or dpop > 0:
		var n_dead: int = maxi(dcorpse, dpop)
		var worst_sp: String = ""
		var worst_drop: int = 0
		for sp in prev_sp:
			var drop: int = int(prev_sp[sp]) - int(cur_sp.get(String(sp), 0))
			if drop > worst_drop:
				worst_drop = drop
				worst_sp = String(sp)
		var verb: String = "was just killed" if dcorpse > 0 else "just died"
		var who: String = _animal_phrase(worst_sp, worst_drop) if worst_sp != "" else "an animal"
		_push_event("%s %s" % [who, verb], I_DEATH + float(n_dead - 1) * 2.0)

	# Births — named by the species that gained the most.
	var best_sp: String = ""
	var best_gain: int = 0
	for sp in cur_sp:
		var gain: int = int(cur_sp[sp]) - int(prev_sp.get(String(sp), 0))
		if gain > best_gain:
			best_gain = gain
			best_sp = String(sp)
	if best_gain > 0:
		_push_event("a newborn %s just appeared" % best_sp, I_BIRTH)

	# Per-species extinction.
	for sp in prev_sp:
		if int(prev_sp[sp]) > 0 and int(cur_sp.get(String(sp), 0)) == 0:
			_push_event("the very last %s has just died out" % String(sp), I_EXTINCT)

	# Behaviour spikes (predation, scavenging, fear) — named per species, with location + prey.
	var prev_ss: Dictionary = prev.get("species_states", {})
	var cur_ss: Dictionary = cur.get("species_states", {})
	var hot: Dictionary = cur.get("hot", {})
	for sp in cur_ss:
		var cs: Dictionary = cur_ss[sp]
		var ps: Dictionary = prev_ss.get(String(sp), {})
		_named_behaviour(String(sp), ps, cs, hot, "stalk", I_STALK)
		_named_behaviour(String(sp), ps, cs, hot, "chase", I_CHASE)
		_named_behaviour(String(sp), ps, cs, hot, "circle", I_CIRCLE)
		_named_behaviour(String(sp), ps, cs, hot, "panic", I_STAMPEDE)

	# Day/night transition.
	var phase: String = _tod_phase(float(cur.get("tod", 0.5)))
	if phase != _last_tod_phase and _last_tod_phase != "":
		_push_event("%s" % phase, I_DAYNIGHT)
	_last_tod_phase = phase


## A named-species behaviour beat: fires when this species FIRST enters a hot state this tick, and builds
## a concrete, reactable sentence with the real animal, its prey, and where it is — not a generic role.
func _named_behaviour(sp: String, prev_states: Dictionary, cur_states: Dictionary, hot: Dictionary, key: String, intensity: float) -> void:
	var count: int = int(cur_states.get(key, 0))
	if not (count > 0 and int(prev_states.get(key, 0)) == 0):
		return
	var info: Dictionary = hot.get(sp + "|" + key, {})
	var loc: String = String(info.get("loc", ""))
	var prey: String = String(info.get("prey", ""))
	var subject: String = _animal_phrase(sp, count)
	var text: String = ""
	match key:
		"stalk":
			if prey != "":
				text = "%s is creeping low through the cover, closing in on %s%s" % [subject, _species_label(prey), loc]
			else:
				text = "%s has dropped into a slow, careful stalk%s" % [subject, loc]
		"chase":
			if prey != "":
				text = "%s has burst into a flat-out sprint after %s%s" % [subject, _species_label(prey), loc]
			else:
				text = "%s is tearing after prey at a dead run%s" % [subject, loc]
		"circle":
			text = "%s are wheeling in slow circles over a fresh carcass%s" % [subject, loc]
		"panic":
			text = "%s have scattered in a wild, bolting panic%s" % [subject, loc]
	if text != "":
		_push_event(text, intensity)


## Natural-language subject for a species: singular "a fox" when one animal drove the beat, the whole
## group "the rabbits" when several did — no bare numbers to parrot.
func _animal_phrase(sp: String, count: int) -> String:
	if count <= 1:
		return "a " + sp
	return "the " + _species_label(sp)


## Where the beat is unfolding, cheap to read from the shared field: at the shore, up high, or (blank)
## just out in the open. Blank stays out of the sentence so the caster isn't forced to name a place.
func _loc_phrase(near_water: bool, y: float, sea: float) -> String:
	if near_water:
		return " right down at the water's edge"
	if y > sea + 24.0:
		return " up on the high ground"
	return ""


## A running-narrative aside: only the INTERESTING part — whether the overall population is swinging up or
## down — as a lowercase fragment, so the model has stakes/continuity but nothing clean to echo as a line.
## Returns "" when nothing notable is trending, so a static scene adds no filler.
func _narrative_clause(snap: Dictionary) -> String:
	if _pop_baseline <= 0.5:
		return ""
	var pop: int = int(snap.get("pop", 0))
	if float(pop) > _pop_baseline * 1.15:
		return "life out here has been really booming lately"
	if float(pop) < _pop_baseline * 0.85:
		return "the land has been steadily emptying out"
	return ""


func _push_event(text: String, intensity: float) -> void:
	_events.append({"text": text, "intensity": intensity})
	_intensity += intensity   # feed the ambient scanner
	while _events.size() > 8:
		_events.pop_front()
	# Landmark events also join the must-say queue so decay + a busy caster can never lose them.
	if intensity >= URGENT_BAR:
		_urgent.append({"text": text, "intensity": intensity})
		while _urgent.size() > URGENT_MAX:
			_urgent.pop_front()   # if the backlog overflows, drop the oldest, keep the freshest beats


## Consume one FIELD-phenomenon event from the shared LAEventTracker (the ONE emergent source, wired in
## VoxelStreamerHost). The tracker already decided WHAT happened and how big it is; the caster just reacts —
## feeding the event's own intensity + narratable description into the same pacing queue its creature beats
## use. This replaces the crude destruction-spike / fire-count scan the director used to run itself.
func on_tracked_event(ev) -> void:
	if ev == null:
		return
	var text: String = String(ev.description)
	if text == "":
		return
	var intensity: float = float(ev.intensity)
	# A big field phenomenon (eruption/impact/flood/storm/lightning) is a mood pivot — forget the calm
	# chatter that came before so the next line reacts to the disaster, not the birdsong.
	if intensity >= URGENT_BAR:
		_reset_window()
	_push_event(text, intensity)


func _tod_phase(tod: float) -> String:
	if tod >= 0.23 and tod < 0.27:
		return "dawn is breaking"
	if tod >= 0.73 and tod < 0.77:
		return "night is falling"
	return "day" if (tod >= 0.25 and tod < 0.75) else "night"


# --- firing a line ------------------------------------------------------------------------------

func _fire(idle: bool) -> void:
	# No brain yet: stay SILENT (there is no canned pool) and leave the events queued — the moment the
	# model server is up, the backlog (volcano and all) gets its reaction.
	if not _server_ready:
		return
	_intensity = 0.0
	_time_since_line = 0.0
	# Lead with the queued landmark events, then the ambient colour; biggest beat first so the caster
	# reacts to the volcano, not the birdsong. Both stores are cleared — everything pending is handed off.
	var events_snapshot: Array = _urgent.duplicate()
	events_snapshot.append_array(_events)
	events_snapshot.sort_custom(func(a, b): return float(a.get("intensity", 0.0)) > float(b.get("intensity", 0.0)))
	_urgent.clear()
	_events.clear()
	# Idle lull: comment on the general conditions; otherwise react to what just happened.
	_dispatch_llm(events_snapshot, idle)


# Put the landmark (must-say) events from a failed request back on the queue so a transient model hiccup
# never loses a volcano — it just reacts a beat later. Ambient colour is allowed to lapse.
func _requeue_urgent(events_snapshot: Array) -> void:
	for e in events_snapshot:
		if float((e as Dictionary).get("intensity", 0.0)) >= URGENT_BAR:
			_urgent.append(e)
	while _urgent.size() > URGENT_MAX:
		_urgent.pop_front()


func _dispatch_llm(events_snapshot: Array, ambient: bool = false) -> void:
	var http: HTTPRequest = HTTPRequest.new()
	add_child(http)
	http.timeout = 8.0
	http.request_completed.connect(_on_llm_completed.bind(http, events_snapshot))

	var user_content: String = _build_ambient_context() if ambient else _build_context(events_snapshot)
	var messages: Array = [{"role": "system", "content": LAStreamerPersonas.system_prompt(_persona_id) + " /no_think"}]
	messages.append_array(_window)
	messages.append({"role": "user", "content": user_content})

	var body: Dictionary = {
		"model": _model_name,
		"messages": messages,
		"temperature": 0.9,
		"top_p": 0.9,
		"frequency_penalty": 0.7,
		"presence_penalty": 0.6,   # nudged up: push the small model off stock phrasing it keeps reaching for
		"max_tokens": 96,          # room for ONE real flowing sentence, not a clipped fragment
		"stream": false,
		# ONE persistent server for the whole session. Persona swaps just change the system prompt on
		# the next request; cache_prompt lets llama.cpp reuse the KV of the shared prefix instead of
		# recomputing (and we never relaunch the server to change voice).
		"cache_prompt": true,
	}
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	var err: int = http.request(_server_url + "/v1/chat/completions", headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		http.queue_free()
		_requeue_urgent(events_snapshot)   # couldn't reach the model — retry the landmark beats, no canned line
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
	# Reject a repeat of anything said recently (the small model latches onto a phrase).
	if line != "" and _said_recently(line):
		line = ""
	if line == "":
		# Nothing usable — say NOTHING (no canned pool), but re-queue the landmark events so the caster
		# retries the important ones next beat instead of dropping them.
		_requeue_urgent(events_snapshot)
		return
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
		mood.append("wildfire smoke drifting through the air")

	# Hand the model ONE beat — the biggest (events_snapshot is sorted biggest-first). Feeding several
	# short declarative beats makes the small model concatenate them verbatim into exactly the staccato
	# "X was killed. Y was killed." fragments we are trying to kill, so we deliberately give it just one.
	var lead: String = "things have gone still for a beat"
	for e in events_snapshot:
		var t: String = String((e as Dictionary).get("text", "")).strip_edges()
		if t != "":
			lead = t
			break
	# Running narrative folds into the opening scene-set (only on a real population swing, so it stays rare
	# and never becomes a fixed tail the small model parrots every line).
	var bg: String = _narrative_clause(snap)
	if bg != "":
		mood.append(bg)

	return ("Right now it's %s. The one thing to react to: %s.\n"
		+ "Put that into your OWN words as ONE fresh, natural, flowing spoken sentence — name the actual "
		+ "animals, never repeat this note back word for word, and never stack clipped fragments.") % [
		", ".join(mood), lead]


## Idle-lull prompt: nothing dramatic is happening, so invite a chill line about the general conditions
## — the weather, the light, the calm, the scenery — the kind of small talk a streamer fills dead air
## with. Grounded in the actual sky/time so "quiet sunny day" or "peaceful night" lands right.
func _build_ambient_context() -> String:
	var snap: Dictionary = _last_sample
	var tod: float = float(snap.get("tod", 0.5))
	var night: bool = tod < 0.25 or tod >= 0.75
	var cloud: float = float(snap.get("cloud", 0.0))
	var sky: String = ""
	if night:
		sky = "a calm, dark night"
	elif cloud > 0.35:
		sky = "an overcast, grey day"
	elif cloud > 0.12:
		sky = "a mild day with a few clouds"
	else:
		sky = "a bright, sunny day"
	var extra: String = ""
	if int(snap.get("fires", 0)) > 0:
		extra = " with a little smoke still drifting"
	var pop: int = int(snap.get("pop", 0))
	var life: String = "the animals are just quietly going about their day"
	if pop <= 6:
		life = "it's pretty sparse out here right now"

	return ("Nothing dramatic is happening. It's %s%s, and %s.\n"
		+ "Fill the dead air with ONE short, chill line about the general conditions or vibe — the "
		+ "weather, the calm, the view. Keep it casual and streamer-friendly; do not recite facts or "
		+ "repeat yourself.") % [sky, extra, life]


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
	# Strip emoji / pictographs (the small model sprinkles them in despite the rules). Keep normal
	# punctuation and typographic dashes/ellipses (all below U+2500).
	var filtered: String = ""
	for i in range(text.length()):
		var c: int = text.unicode_at(i)
		if c < 0x2500:
			filtered += char(c)
	text = filtered.strip_edges()
	if text.begins_with("- "):
		text = text.substr(2)
	if text.length() > 200:
		text = text.substr(0, 200).strip_edges() + "…"
	return text


func _cloud_cover() -> float:
	if _world == null or _world.get("_material") == null:
		return 0.0
	var mat = _world.get("_material")
	if mat != null and mat.has_method("avg_cloud_cover"):
		return float(mat.avg_cloud_cover())
	return 0.0


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
