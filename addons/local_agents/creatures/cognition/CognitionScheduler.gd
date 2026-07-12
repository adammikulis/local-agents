class_name LACognitionScheduler
extends Node

## The shared "slow brain" throttle. Every creature's LACognition escalates rare/uncertain
## situations here; this one node decides — for the WHOLE world at once — whether there is budget to
## resolve another deliberation right now, resolves it OFF the physics frame, and writes a training
## trace for the auto-finetune loop. It is deliberately the only place that talks to the model server
## so the global concurrency/rate caps are honoured no matter how many creatures escalate at once.
##
## Two backends resolve an escalation into one LAActionRegistry action:
##   1. The shared LLMClient — a LocalAgentLlmClient (a LocalAgent behind an async seam), owned by
##      LALlmService and injected by EcologyService. request() runs the native function-calling think
##      OFF the frame and hands back the chosen tool call. Used when a client is injected and we are
##      inside the tree. This is the SAME LocalAgent the standalone agent + streamer use — one server,
##      one model, one config (no more private HTTPRequest client here).
##   2. Heuristic teacher — a synchronous rule-of-thumb resolved from the signature+context, but its
##      callback is DEFERRED so it too never blocks. This is the offline fallback AND the "teacher"
##      that keeps generating training traces when no model is loaded.
##
## Either way the result is fed back via `cognition.apply_llm_result(key, action)` (success) or
## `cognition.on_llm_failed()` (failure/timeout), and — on success — appended as one JSONL trace line.
##
## (Explicit types only — project rule: no ':=' inferred typing.)

const DEFAULT_TRACE_PATH: String = "user://functiongemma_traces.jsonl"
const SCAN_LIMIT: int = 40                 # per-group cap when gathering escalation context
const PREDATOR_SIZE_RATIO: float = 1.2     # a "predator" must be at least this much bigger than me
# How long the "thinking"/"queued" highlight lingers after the event so the player (and a screenshot) can
# actually SEE a consult that resolved in a single frame (the teacher path resolves next idle). Purely a
# display window — the authoritative in-flight state (is_thinking) is exact via _in_flight_ids.
const HIGHLIGHT_LINGER_MS: int = 1200
const ACTIVITY_PRUNE_AT: int = 256         # prune expired activity entries once the map grows past this

# --- configuration (set via setup) ---
var _enabled: bool = true
# The shared LLMClient (a LocalAgentLlmClient owned by LALlmService), injected by EcologyService. When
# null the scheduler resolves every escalation with the built-in heuristic teacher (the offline path).
# This replaces the old raw HTTPRequest + server_url/model plumbing: one client, one server, one model.
var _llm_client = null
var _trace_path: String = DEFAULT_TRACE_PATH
var _max_in_flight: int = 2
var _max_rps: float = 4.0

# --- live budget / stats ---
var _in_flight: int = 0
var _total_calls: int = 0
var _llm_calls: int = 0
var _teacher_calls: int = 0
var _dropped: int = 0
var _recent_ms: Array = []                 # accept timestamps within the last second (rate limiting)

# --- live "who is consulting the slow brain" set (drives the player's thinking/queued highlight + select) ---
# _in_flight_ids: exact set of creatures whose escalation is being resolved RIGHT NOW (added on accept,
# removed on finish). _activity: instance_id -> {kind:"thinking"|"queued", until:msec} — the lingered
# display window so a one-frame teacher consult still shows. is_thinking/is_queued read both.
var _in_flight_ids: Dictionary = {}
var _activity: Dictionary = {}


## Configure the scheduler. Robust to a missing llm_client (falls back to the teacher for every call).
func setup(options: Dictionary = {}) -> void:
	_enabled = bool(options.get("enabled", true))
	_llm_client = options.get("llm_client", null)
	_trace_path = String(options.get("trace_path", DEFAULT_TRACE_PATH))
	_max_in_flight = maxi(1, int(options.get("max_in_flight", 2)))
	_max_rps = maxf(0.1, float(options.get("max_rps", 4.0)))


## The escalation entry point called by LACognition. Returns true if the request was accepted (a
## result WILL come back asynchronously), false if the global budget is full (caller stays on the
## fast path). Never blocks the physics frame.
func request(creature, cognition, sig: Dictionary, innate_action: String) -> bool:
	if cognition == null:
		return false
	var cid: int = creature.get_instance_id() if creature != null else 0
	if not _accept():
		_dropped += 1
		# Wanted to consult the slow brain but the shared budget was full → mark QUEUED (waiting its turn).
		if cid != 0:
			_activity[cid] = {"kind": "queued", "until": Time.get_ticks_msec() + HIGHLIGHT_LINGER_MS}
			_maybe_prune()
		return false

	_in_flight += 1
	_total_calls += 1
	# Accepted → this creature is now consulting the slow brain (THINKING), exact until _finish clears it.
	if cid != 0:
		_in_flight_ids[cid] = true
		_activity[cid] = {"kind": "thinking", "until": Time.get_ticks_msec() + HIGHLIGHT_LINGER_MS}
		_maybe_prune()          # bound the map on this add path too (not just the drop path) — else it leaks

	var context: Dictionary = _gather_context(creature)
	var job: Dictionary = {
		"creature": creature,
		"cognition": cognition,
		"cid": cid,
		"sig": sig,
		"innate_action": String(innate_action),
		"context": context,
	}

	if _enabled and _llm_client != null and is_inside_tree():
		if _dispatch_llm(job):
			return true
		# The shared client was busy/unavailable — fall through to the teacher so we still resolve.
	call_deferred("_resolve_teacher", job)
	return true


## Global budget gate: cap concurrent in-flight resolutions AND requests-per-second. Records the
## accept timestamp when it lets one through.
func _accept() -> bool:
	if _in_flight >= _max_in_flight:
		return false
	var now: int = Time.get_ticks_msec()
	var cutoff: int = now - 1000
	while _recent_ms.size() > 0 and int(_recent_ms[0]) < cutoff:
		_recent_ms.remove_at(0)
	if float(_recent_ms.size()) >= _max_rps:
		return false
	_recent_ms.append(now)
	return true


# --- shared-LLMClient backend (function-calling) --------------------------------------------------

## Dispatch one escalation through the shared LocalAgentLlmClient. FunctionGemmaClient shapes the
## messages; the client supplies transport + tools + tool_choice and delivers the native result async.
## Returns false when the client rejects (already in flight) so the caller falls back to the teacher.
func _dispatch_llm(job: Dictionary) -> bool:
	if _llm_client == null:
		return false
	var messages: Array = LAFunctionGemmaClient.build_messages(job["sig"], job["context"])
	var tools: Array = LAActionRegistry.tool_specs()
	var accepted: bool = bool(_llm_client.request(messages, tools, {}, _on_llm_result.bind(job)))
	if not accepted:
		return false
	_llm_calls += 1
	return true


## Async result from the shared client: the native think Dictionary ({ok, text, tool_calls?, response?}).
## FunctionGemmaClient reads the chosen action out of it (native tool-call first, then a content scan). If
## the model itself was unavailable (ok:false — server down, model not loaded) we DEGRADE to the heuristic
## teacher so a broken/offline model never breaks cognition; a model that answered but chose no valid
## action still reports failure (the creature keeps its fast-path pick).
func _on_llm_result(result: Dictionary, job: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_resolve_teacher(job)
		return
	var action: String = LAFunctionGemmaClient.parse_action_from_result(result)
	_finish(job, action, "llm")


# --- heuristic teacher backend --------------------------------------------------------------------

func _resolve_teacher(job: Dictionary) -> void:
	_teacher_calls += 1
	var action: String = _teacher_action(job["sig"], job["context"])
	_finish(job, action, "teacher")


## Rule-of-thumb policy over the signature + gathered context. Always yields a valid action (worst
## case "wander"), so the teacher path never reports failure.
func _teacher_action(sig: Dictionary, context: Dictionary) -> String:
	var h: int = int(sig.get("h", 2))
	var e: int = int(sig.get("e", 3))
	var at_water: bool = bool(context.get("at_water", false))
	var diet: String = String(context.get("diet", "herbivore"))
	var predator_visible: bool = bool(context.get("predator_visible", false))

	if h == 0 and at_water:
		return "drink"
	if h == 0:
		return "seek_water"
	if e <= 1 and bool(context.get("plant_visible", false)):
		return "graze"
	if (diet == "carnivore" or diet == "omnivore") and bool(context.get("prey_visible", false)):
		return "hunt"
	if e <= 1 and not predator_visible:
		return "rest"
	return "wander"


# --- shared resolution / feedback -----------------------------------------------------------------

func _finish(job: Dictionary, action: String, source: String) -> void:
	_in_flight = maxi(0, _in_flight - 1)
	# Resolved: drop the exact in-flight mark but keep a lingering "thinking" glow so a fast (single-frame)
	# consult is still visible for a moment after it lands.
	var cid: int = int(job.get("cid", 0))
	if cid != 0:
		_in_flight_ids.erase(cid)
		_activity[cid] = {"kind": "thinking", "until": Time.get_ticks_msec() + HIGHLIGHT_LINGER_MS}
		_maybe_prune()          # bound the map on the finish path too — else it leaks for always-accepted creatures
	var cognition = job.get("cognition", null)
	if action != "" and LAActionRegistry.is_valid(action):
		_write_trace(job, action, source)
		if cognition != null and is_instance_valid(cognition):
			# Pass the source + full signature so the creature can surface WHO decided (local model vs
			# offline teacher) and phrase it as a natural-language thought in the inspector.
			cognition.apply_llm_result(int(job["sig"].get("key", -1)), action, source, job["sig"])
	else:
		if cognition != null and is_instance_valid(cognition):
			cognition.on_llm_failed()


# --- rich context gathering (rare, escalation-time only) ------------------------------------------

## Scan the world (bounded, vision-gated) for what matters to a survival decision. Only called when a
## creature actually escalates, so the O(groups) scan cost is acceptable.
func _gather_context(creature) -> Dictionary:
	var e_frac: float = 0.0
	if creature != null and float(creature.max_energy) > 0.0:
		e_frac = clampf(float(creature.energy) / float(creature.max_energy), 0.0, 1.0)
	var h_frac: float = 0.0
	if creature != null and float(creature.max_hydration) > 0.0:
		h_frac = clampf(float(creature.hydration) / float(creature.max_hydration), 0.0, 1.0)

	var at_water: bool = false
	if creature != null and creature._material != null and creature._material.has_method("is_water_at"):
		at_water = creature._material.is_water_at(creature.global_position)
	var night: bool = false
	if creature != null and creature._ecology != null and creature._ecology.has_method("is_night"):
		night = creature._ecology.is_night()

	var predator_visible: bool = false
	var prey_visible: bool = false
	var plant_visible: bool = false
	var carrion_visible: bool = false

	var tree: SceneTree = null
	if creature != null and creature.is_inside_tree():
		tree = creature.get_tree()
	if tree != null:
		predator_visible = _scan_predators(creature, tree)
		prey_visible = _scan_prey(creature, tree)
		plant_visible = _scan_group_visible(creature, tree, "plant")
		carrion_visible = _scan_group_visible(creature, tree, "carrion")

	return {
		"energy_frac": e_frac,
		"hydration_frac": h_frac,
		"at_water": at_water,
		"night": night,
		"predator_visible": predator_visible,
		"prey_visible": prey_visible,
		"plant_visible": plant_visible,
		"carrion_visible": carrion_visible,
		"species": String(creature.species) if creature != null else "",
		"diet": String(creature.diet) if creature != null else "",
	}


func _scan_predators(creature, tree: SceneTree) -> bool:
	var my_size: float = float(creature.size)
	var count: int = 0
	for n in tree.get_nodes_in_group("creature"):
		if count >= SCAN_LIMIT:
			break
		count += 1
		if n == creature or not is_instance_valid(n):
			continue
		if not n.has_method("is_hunter") or not n.is_hunter():
			continue
		var other_size = n.get("size")
		if other_size == null or float(other_size) < my_size * PREDATOR_SIZE_RATIO:
			continue
		if LAVision.sees_node(creature, n):
			return true
	return false


func _scan_prey(creature, tree: SceneTree) -> bool:
	for sp in creature.preys_on:
		var count: int = 0
		for n in tree.get_nodes_in_group("species_" + String(sp)):
			if count >= SCAN_LIMIT:
				break
			count += 1
			if n == creature or not is_instance_valid(n):
				continue
			if LAVision.sees_node(creature, n):
				return true
	return false


func _scan_group_visible(creature, tree: SceneTree, group: String) -> bool:
	var count: int = 0
	for n in tree.get_nodes_in_group(group):
		if count >= SCAN_LIMIT:
			break
		count += 1
		if not is_instance_valid(n):
			continue
		if LAVision.sees_node(creature, n):
			return true
	return false


# --- trace logging (fixed schema — the finetune exporter reads this) ------------------------------

func _write_trace(job: Dictionary, action: String, source: String) -> void:
	if _trace_path == "":
		return
	var ctx: Dictionary = job["context"]
	var sig: Dictionary = job["sig"]
	var line: Dictionary = {
		"sig_key": int(sig.get("key", -1)),
		"sig_text": String(sig.get("text", "")),
		"species": String(ctx.get("species", "")),
		"diet": String(ctx.get("diet", "")),
		"context": {
			"energy_frac": float(ctx.get("energy_frac", 0.0)),
			"hydration_frac": float(ctx.get("hydration_frac", 0.0)),
			"at_water": bool(ctx.get("at_water", false)),
			"night": bool(ctx.get("night", false)),
			"predator_visible": bool(ctx.get("predator_visible", false)),
			"prey_visible": bool(ctx.get("prey_visible", false)),
			"plant_visible": bool(ctx.get("plant_visible", false)),
			"carrion_visible": bool(ctx.get("carrion_visible", false)),
		},
		"tools": _action_name_list(),
		"innate_action": String(job.get("innate_action", "")),
		"chosen_action": action,
		"source": source,
	}
	var f: FileAccess = FileAccess.open(_trace_path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(_trace_path, FileAccess.WRITE)   # first write — create the file
	if f == null:
		return
	f.seek_end()
	f.store_line(JSON.stringify(line))
	f.close()


func _action_name_list() -> Array:
	var names: Array = []
	for a in LAActionRegistry.ACTIONS:
		names.append(String(a))
	return names


# --- live consult set (player highlight + select-by-predicate) ------------------------------------

## Is this creature consulting the slow brain right now (or within the brief display linger)? Exact while
## the escalation is in flight (_in_flight_ids), then lingers HIGHLIGHT_LINGER_MS so a one-frame teacher
## consult is still visible. O(1).
func is_thinking(c) -> bool:
	if c == null:
		return false
	var cid: int = c.get_instance_id()
	if _in_flight_ids.has(cid):
		return true
	return _activity_kind(cid) == "thinking"


## Did this creature want to escalate but get held back by the shared budget (waiting its turn)? Cleared
## the moment it is actually accepted (it becomes thinking then). O(1).
func is_queued(c) -> bool:
	if c == null:
		return false
	var cid: int = c.get_instance_id()
	if _in_flight_ids.has(cid):
		return false
	return _activity_kind(cid) == "queued"


# The current lingered activity kind for `cid` ("thinking"|"queued"|""), self-pruning expired entries.
func _activity_kind(cid: int) -> String:
	var e = _activity.get(cid, null)
	if e == null:
		return ""
	if Time.get_ticks_msec() >= int((e as Dictionary).get("until", 0)):
		_activity.erase(cid)
		return ""
	return String((e as Dictionary).get("kind", ""))


# Drop expired activity entries when the map grows (bounds memory for creatures that never query again).
func _maybe_prune() -> void:
	if _activity.size() < ACTIVITY_PRUNE_AT:
		return
	var now: int = Time.get_ticks_msec()
	for k in _activity.keys():
		if now >= int((_activity[k] as Dictionary).get("until", 0)):
			_activity.erase(k)


# --- introspection --------------------------------------------------------------------------------

func stats() -> Dictionary:
	return {
		"in_flight": _in_flight,
		"total_calls": _total_calls,
		"llm_calls": _llm_calls,
		"teacher_calls": _teacher_calls,
		"dropped": _dropped,
	}


func total_calls() -> int:
	return _total_calls
