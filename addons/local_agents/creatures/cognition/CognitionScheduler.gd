@icon("res://addons/local_agents/icons/local_agent_scheduler.svg")
class_name LocalAgentCognitionScheduler
extends Node

## The shared "slow brain" throttle. Every creature's LACognition escalates rare/uncertain
## situations here; this one node decides (for the WHOLE world at once) whether there is budget to
## resolve another deliberation right now, resolves it OFF the physics frame, and writes a training
## trace for the auto-finetune loop. It is deliberately the only place that talks to the model server
## so the global concurrency/rate caps are honoured no matter how many creatures escalate at once.
##
## Two backends resolve an escalation into one LAActionRegistry action:
##   1. The shared LLMClient: a LocalAgentLlmClient (a LocalAgent behind an async seam), owned by
##      LocalAgentLlmService. request() runs the native function-calling think OFF the frame and hands
##      back the chosen tool call. Used when a service/client is available and we are inside the tree.
##      This is the SAME LocalAgent the standalone agent + streamer use: one server, one model, one
##      config (no more private HTTPRequest client here).
##   2. Heuristic teacher: a synchronous rule-of-thumb resolved from the signature+context, but its
##      callback is DEFERRED so it too never blocks. This is the offline fallback AND the "teacher"
##      that keeps generating training traces when no model is loaded.
##
## Either way the result is fed back via `cognition.apply_llm_result(key, action)` (success) or
## `cognition.on_llm_failed()` (failure/timeout), and on success appended as one JSONL trace line.
##
## NO-CODE USE: drop this node into a scene next to a LocalAgentLlmService, pick that service in
## `llm_service`, and every creature in `adopt_group` is wired to it on ready, including creatures
## spawned later. That is the whole hookup; no script is involved.
##
## (Explicit types only, no ':=' inferred typing.)

const DEFAULT_TRACE_PATH: String = "user://functiongemma_traces.jsonl"
const SCAN_LIMIT: int = 40                 # per-group cap when gathering escalation context
const PREDATOR_SIZE_RATIO: float = 1.2     # a "predator" must be at least this much bigger than me
const ACTIVITY_PRUNE_AT: int = 256         # prune expired activity entries once the map grows past this

## Emitted ONCE per scheduler, the first time an escalation falls back to the heuristic teacher instead
## of the model. `reason` is a sentence naming the cause and the fix. It is a signal rather than a print
## because the fallback is correct behaviour that fires per-creature per-second, and logging every one
## would flood the console. Connect it to a HUD line if you want it surfaced.
signal degraded(reason: String)


@export_group("Model")

## The shared LLM service (a LocalAgentLlmService node) every escalation is resolved through. Leave
## empty, or leave the service disabled, and every escalation resolves with the built-in heuristic
## teacher instead, which still plays correctly and still writes training traces.
@export var llm_service: LocalAgentLlmService

## Master switch for the slow brain. Off sends every escalation straight to the heuristic teacher and
## never touches the model, which is the cheapest way to A/B the model against the rules of thumb.
@export var enabled: bool = true

@export_group("Budget")

## How many slow-brain resolutions may be in flight at once across the WHOLE world. One shared server
## answers them all, so this is the knob that stops a thousand creatures queueing behind each other.
@export_range(1, 16, 1) var max_in_flight: int = 2

## Ceiling on how many escalations per second are accepted world-wide. Escalations over the ceiling are
## dropped, and those creatures keep the action their fast brain already picked.
@export_range(0.1, 60.0, 0.1, "suffix:/s") var max_requests_per_second: float = 4.0

## How long the "thinking"/"queued" highlight stays on a creature after its consult resolves, so a
## decision that took a single frame is still visible. Display only. It changes no behaviour.
@export_range(0, 10000, 50, "suffix:ms") var highlight_linger_ms: int = 1200

@export_group("Training traces")

## Append one JSONL line per resolved escalation (the situation, the options, the chosen action, and
## who chose it). This is the dataset the auto-finetune loop trains on. Off writes nothing.
@export var write_traces: bool = true

## Folder the trace file is written into. "user://" is the per-project writable folder, which is the
## right place for it, because res:// is read-only in an exported game.
## Left a plain String rather than @export_dir: that picker is res://-scoped and cannot browse to
## user://, so it could not express this property's own default.
@export var trace_dir: String = "user://"

## Name of the trace file inside the folder above. Lines are appended, never overwritten.
@export var trace_filename: String = "functiongemma_traces.jsonl"

@export_group("Auto-adopt")

## Creatures in this group are wired to this scheduler automatically: on ready for the ones already in
## the scene, and as they are added for the ones spawned later. Clear it to disable auto-adoption and
## wire creatures yourself with set_cognition_scheduler().
@export var adopt_group: StringName = &"la_creatures"


# --- configuration (set via setup) ---
# The shared LLMClient (a LocalAgentLlmClient owned by LocalAgentLlmService), injected by setup(). When
# null the scheduler asks `llm_service` for one; when that is null too, every escalation resolves with
# the built-in heuristic teacher (the offline path). This replaces the old raw HTTPRequest +
# server_url/model plumbing: one client, one server, one model.
var _llm_client = null
var _trace_path_override: String = ""      # setup({"trace_path": ...}) wins over the exports above
var _degraded_reported: bool = false       # `degraded` is emitted at most once

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


## Programmatic override of the inspector exports above. Robust to a missing service/client — it falls
## back to the heuristic teacher for every call. Keys: enabled, llm_service, llm_client, trace_path,
## max_in_flight, max_rps.
func setup(options: Dictionary = {}) -> void:
	enabled = bool(options.get("enabled", enabled))
	if options.has("llm_service"):
		llm_service = options["llm_service"]
	if options.has("llm_client"):
		_llm_client = options["llm_client"]
	_trace_path_override = String(options.get("trace_path", ""))
	max_in_flight = maxi(1, int(options.get("max_in_flight", max_in_flight)))
	max_requests_per_second = maxf(0.1, float(options.get("max_rps", max_requests_per_second)))


## Adopt every creature already in `adopt_group`, then keep adopting the ones spawned later. This lives
## in the scheduler so Creature.gd needs no knowledge of it: a creature only has to be in the group.
func _ready() -> void:
	_adopt_existing()
	var tree: SceneTree = get_tree()
	if tree != null and not tree.node_added.is_connected(_on_node_added):
		tree.node_added.connect(_on_node_added)


## One summary line for the whole run: how the world's escalations were actually resolved. The
## per-escalation teacher fallback is deliberately silent (it fires per-creature per-second); this is
## where you find out whether the model was doing the deciding or the rules of thumb were.
func _exit_tree() -> void:
	var tree: SceneTree = get_tree()
	if tree != null and tree.node_added.is_connected(_on_node_added):
		tree.node_added.disconnect(_on_node_added)
	if _total_calls > 0:
		print("LocalAgentCognitionScheduler: %d escalations, %d dispatched to the model, %d resolved by the heuristic teacher, %d dropped (budget full)." % [_total_calls, _llm_calls, _teacher_calls, _dropped])


func _adopt_existing() -> void:
	if adopt_group == &"":
		return
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	for node in tree.get_nodes_in_group(adopt_group):
		_try_adopt(node)


# node_added fires for EVERY node in the scene, so the check is cheap and the work is deferred.
#
# Deferred ALWAYS, including for a node already in the group. node_added fires during add_child,
# which is before the spawner calls setup(). Creature.set_cognition_scheduler() is
# `if _cognition != null: _cognition.set_scheduler(s)`, and _cognition is not built until setup()
# runs — so adopting at add_child time is a SILENT no-op and the creature ends up with no scheduler
# at all. Deferring also covers the other direction, where a spawner calls add_to_group() after
# add_child().
func _on_node_added(node: Node) -> void:
	if adopt_group == &"" or node == null:
		return
	if node.is_in_group(adopt_group) or node.has_method("set_cognition_scheduler"):
		call_deferred("_try_adopt", node)


func _try_adopt(node) -> void:
	if node == null or not is_instance_valid(node):
		return
	if not (node as Node).is_in_group(adopt_group):
		return
	if not (node as Node).has_method("set_cognition_scheduler"):
		return
	(node as Node).set_cognition_scheduler(self)


# The shared client: an explicitly injected one wins, else the assigned service's — but only while that
# service reports itself available (a disabled or model-less service must not be asked for one).
func _client_or_null():
	if _llm_client != null:
		return _llm_client
	if llm_service == null or not is_instance_valid(llm_service):
		return null
	if llm_service.has_method("is_available") and not bool(llm_service.is_available()):
		return null
	if not llm_service.has_method("client"):
		return null
	return llm_service.client()


# Where trace lines are appended: setup()'s explicit path wins, else the exported folder + filename.
# "" when tracing is off, which _write_trace treats as "write nothing".
func _resolve_trace_path() -> String:
	if not write_traces:
		return ""
	if _trace_path_override != "":
		return _trace_path_override
	var dir: String = trace_dir.strip_edges()
	if dir == "":
		return DEFAULT_TRACE_PATH
	if not dir.ends_with("/"):
		dir += "/"
	var file_name: String = trace_filename.strip_edges()
	if file_name == "":
		return ""
	return dir + file_name


# Emit `degraded` at most once, naming why the model is not deciding and what to change.
func _note_degraded() -> void:
	if _degraded_reported:
		return
	_degraded_reported = true
	degraded.emit(_degrade_reason())


func _degrade_reason() -> String:
	if not enabled:
		return "The cognition scheduler is disabled, so every decision comes from the built-in heuristic teacher."
	if _llm_client == null and (llm_service == null or not is_instance_valid(llm_service)):
		return "No LLM service is assigned, so every decision comes from the built-in heuristic teacher. Add a LocalAgentLlmService to the scene and pick it in this node's 'Llm Service' property."
	if llm_service != null and is_instance_valid(llm_service) and llm_service.has_method("is_available") and not bool(llm_service.is_available()):
		if llm_service.has_method("offline_reason"):
			return "The shared LLM service is offline, so decisions come from the built-in heuristic teacher: %s" % String(llm_service.offline_reason())
		return "The shared LLM service reports itself unavailable, so decisions come from the built-in heuristic teacher."
	return "The shared LLM client was busy or the request failed, so this decision came from the built-in heuristic teacher."


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
			_activity[cid] = {"kind": "queued", "until": Time.get_ticks_msec() + highlight_linger_ms}
			_maybe_prune()
		return false

	_in_flight += 1
	_total_calls += 1
	# Accepted → this creature is now consulting the slow brain (THINKING), exact until _finish clears it.
	if cid != 0:
		_in_flight_ids[cid] = true
		_activity[cid] = {"kind": "thinking", "until": Time.get_ticks_msec() + highlight_linger_ms}
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

	if enabled and is_inside_tree():
		if _dispatch_llm(job):
			return true
		# The shared client was busy/unavailable — fall through to the teacher so we still resolve.
	call_deferred("_resolve_teacher", job)
	return true


## Global budget gate: cap concurrent in-flight resolutions AND requests-per-second. Records the
## accept timestamp when it lets one through.
func _accept() -> bool:
	if _in_flight >= max_in_flight:
		return false
	var now: int = Time.get_ticks_msec()
	var cutoff: int = now - 1000
	while _recent_ms.size() > 0 and int(_recent_ms[0]) < cutoff:
		_recent_ms.remove_at(0)
	if float(_recent_ms.size()) >= max_requests_per_second:
		return false
	_recent_ms.append(now)
	return true


# --- shared-LLMClient backend (function-calling) --------------------------------------------------

## Dispatch one escalation through the shared LocalAgentLlmClient. FunctionGemmaClient shapes the
## messages; the client supplies transport + tools + tool_choice and delivers the native result async.
## Returns false when the client rejects (already in flight) so the caller falls back to the teacher.
func _dispatch_llm(job: Dictionary) -> bool:
	var llm_client = _client_or_null()
	if llm_client == null:
		return false
	var messages: Array = LAFunctionGemmaClient.build_messages(job["sig"], job["context"])
	var tools: Array = LAActionRegistry.tool_specs()
	var accepted: bool = bool(llm_client.request(messages, tools, {}, _on_llm_result.bind(job)))
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
	# Say ONCE (via the signal, not the console) that the model is not the one deciding. The fallback
	# itself is correct behaviour and fires constantly, so it stays otherwise silent.
	_note_degraded()
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
		_activity[cid] = {"kind": "thinking", "until": Time.get_ticks_msec() + highlight_linger_ms}
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
	var trace_path: String = _resolve_trace_path()
	if trace_path == "":
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
	var f: FileAccess = FileAccess.open(trace_path, FileAccess.READ_WRITE)
	if f == null:
		DirAccess.make_dir_recursive_absolute(trace_path.get_base_dir())   # a chosen folder may not exist yet
		f = FileAccess.open(trace_path, FileAccess.WRITE)   # first write — create the file
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
## the escalation is in flight (_in_flight_ids), then lingers highlight_linger_ms so a one-frame teacher
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
