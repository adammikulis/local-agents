class_name LAAgentBackstory
extends RefCounted

## Gives a LocalAgent a long memory, by connecting it to LocalAgentBackstoryGraphService.
##
## Why this exists. The addon shipped two memory stores. `LocalAgentGraph` is 87 lines of
## add_node/add_edge that the agent already writes every turn into, and it forgets nothing and recalls
## nothing: there is no query in it that answers "what does this character remember about that". The
## other is `graph/BackstoryGraphService.gd`, 1955 lines over nine files, SQLite-backed, with
## relationship state, dream and thought memories, oral-knowledge lineage, world-truth versus per-NPC
## belief, contradiction detection, and vector search over memory embeddings. It was complete, it had a
## passing test, and NOTHING in the addon called it. The README's "SQLite-backed graph store with
## vector search for agent memory" was describing the one nobody could reach.
##
## So this is the wire, not a new system. It is a separate module rather than more lines in Agent.gd
## for the same reason AgentHistory, AgentSpeech and AgentJobs are: the agent stays a thin surface over
## a handful of concerns it delegates to.
##
## The two directions:
##   - WRITE. Every user line and every model reply is ingested as a memory against `npc_id`, on top of
##     the ordinary `memory_graph` recording, which is untouched. Both can be on at once; they answer
##     different questions.
##   - READ. Before a prompt goes to the model, recall the memories most relevant to it and hand them
##     back as context. Semantic search first, because that is the point of storing embeddings. If the
##     embedding backend is not up (it needs llama-server started with --embeddings) it falls back to
##     the most recent and most important memories, which needs no server at all.
##
## Nothing here is required. An agent with no `backstory` assigned behaves exactly as before.
##
## (Explicit types only, project rule: no ':=' inferred typing.)

## How many recalled memories to put in front of a prompt. Small on purpose: this text is prepended to
## every request, so it is paid for in tokens on every turn, and a long wall of half-relevant memory
## makes replies worse rather than better.
const DEFAULT_RECALL_LIMIT: int = 6

## Written into the memory's importance field. Conversation lines are ordinary events, so they sit
## mid-scale and are outranked by anything a game explicitly records as significant.
const CONVERSATION_IMPORTANCE: float = 0.45
const CONVERSATION_CONFIDENCE: float = 0.9

var _service: Node = null
var _npc_id: String = ""
var _seq: int = 0                 # per-agent message counter, so memory ids do not collide
var _npc_ensured: bool = false
var _warned_unavailable: bool = false


## Point this at a LocalAgentBackstoryGraphService and the id this agent is known by in the graph.
## Passing null, or an empty id, leaves the agent with no long memory and is not an error.
func attach(service: Node, npc_id: String, display_name: String = "") -> void:
	_service = service
	_npc_id = npc_id.strip_edges()
	_npc_ensured = false
	if _service != null and _npc_id != "" and display_name != "":
		_ensure_npc(display_name)


func is_active() -> bool:
	return _service != null and _npc_id != "" and _service.has_method("add_memory")


## Record one conversation line as a memory. Safe to call when nothing is attached.
##
## The memory id is built from this agent's own counter rather than from the message, because
## ingest_conversation_message_as_memory() falls back to `msg_-1` for any message with no `id` field,
## and the agent's history entries do not carry one. Two lines both landing on `msg_-1` would upsert
## over each other and the agent would remember exactly one thing.
func record(role: String, content: String, world_day: int = -1) -> void:
	if not is_active() or content.strip_edges() == "":
		return
	_seq += 1
	var memory_id: String = "%s_turn_%d_%s" % [_npc_id, _seq, role]
	var message: Dictionary = {"content": content, "role": role}
	var result: Variant = _service.call(
		"ingest_conversation_message_as_memory", _npc_id, message, memory_id, world_day,
		CONVERSATION_IMPORTANCE, CONVERSATION_CONFIDENCE)
	_warn_once_on_failure(result, "record a memory")


## The memories most worth putting in front of `prompt`, newest last, as plain sentences.
##
## Returns "" when nothing is attached, nothing is remembered, or the store cannot answer. A caller
## should treat "" as "no context", never as an error.
func recall(prompt: String, limit: int = DEFAULT_RECALL_LIMIT) -> String:
	if not is_active() or limit <= 0:
		return ""
	var lines: PackedStringArray = _semantic_recall(prompt, limit)
	if lines.is_empty():
		lines = _recent_recall(limit)
	if lines.is_empty():
		return ""
	return "\n".join(lines)


## Semantic recall over the memory embeddings. This is the reason the embeddings are stored, and it is
## also the half that needs llama-server running with --embeddings, so an empty result here is the
## normal state on a machine without one rather than a failure worth warning about.
func _semantic_recall(prompt: String, limit: int) -> PackedStringArray:
	if prompt.strip_edges() == "" or not _service.has_method("search_memory_embeddings"):
		return PackedStringArray()
	var result: Variant = _service.call("search_memory_embeddings", _npc_id, prompt, limit)
	return _summaries_from(result)


## No server needed: the most recent and most important memories this character holds.
func _recent_recall(limit: int) -> PackedStringArray:
	if not _service.has_method("get_memory_recall_candidates"):
		return PackedStringArray()
	var result: Variant = _service.call("get_memory_recall_candidates", _npc_id, -1, limit, true)
	return _summaries_from(result)


## Row keys used by BackstoryMemoryStateOps, read out of it rather than guessed: `candidates` from
## get_memory_recall_candidates (:329), `results` from search_memory_embeddings (:410), `memories` from
## get_backstory_context (:280). I originally invented three plausible names, none of which was
## `candidates`, and the wiring silently recalled nothing while every call returned ok.
const ROW_KEYS: Array = ["candidates", "results", "memories"]


## Both recall calls answer with the service's usual {ok, ...} envelope around a row list. Pull the
## human-readable summary out of whichever key carries the rows, and skip anything shapeless rather
## than guessing, so a schema change degrades to fewer memories instead of to garbage in the prompt.
func _summaries_from(result: Variant) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if not (result is Dictionary):
		return out
	var payload: Dictionary = result
	if not bool(payload.get("ok", false)):
		return out
	var rows: Variant = []
	for key in ROW_KEYS:
		if payload.has(key) and payload[key] is Array:
			rows = payload[key]
			break
	if not (rows is Array):
		return out
	for row_v in (rows as Array):
		if not (row_v is Dictionary):
			continue
		var row: Dictionary = row_v
		var summary: String = String(row.get("summary", row.get("content", ""))).strip_edges()
		if summary != "":
			out.append(summary)
	return out


func _ensure_npc(display_name: String) -> void:
	if _npc_ensured or not _service.has_method("upsert_npc"):
		return
	_npc_ensured = true
	_service.call("upsert_npc", _npc_id, display_name)


## One warning per agent, not one per turn. A store that cannot be written to fails on every single
## line, and the useful signal is the first one.
func _warn_once_on_failure(result: Variant, what: String) -> void:
	if _warned_unavailable or not (result is Dictionary):
		return
	var payload: Dictionary = result
	if bool(payload.get("ok", false)):
		return
	_warned_unavailable = true
	push_warning("Local Agents: could not %s for '%s' (%s). The agent still talks and still uses its Memory Graph, it just will not remember across sessions." % [
		what, _npc_id, String(payload.get("error", "unknown"))])
