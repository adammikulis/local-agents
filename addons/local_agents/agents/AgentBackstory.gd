class_name LAAgentBackstory
extends RefCounted


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
