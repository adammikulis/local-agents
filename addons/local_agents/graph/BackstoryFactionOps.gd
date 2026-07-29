@tool
extends RefCounted
class_name LocalAgentBackstoryFactionOps

## Faction / membership operations the store was missing.
##
## LocalAgentBackstoryGraphService could already OPEN a dated membership — upsert_faction() plus
## add_relationship(..., "MEMBER_OF", from_day, to_day, ...) — and read the open ones back through
## get_backstory_context(), which applies the from_day/to_day window. It could not CLOSE one, and it could
## not read a membership that had already ended, so "which band did this animal belong to before it left"
## had no answer and a life could only ever accumulate memberships.
##
## Closing an edge is done by rewriting it, because NetworkGraph binds add_edge / remove_edge / get_edges
## and no edge-update call (see NetworkGraph.cpp _bind_methods). get_edges returns each row's `id`, so a
## close is: copy the row's data with `to_day` stamped, add the copy, drop the original. Both calls are
## synchronous against the same SQLite handle.
##
## These live in the ops layer next to their siblings rather than as new bodies on the service, which stays
## a thin facade of forwarders. (Explicit types only, no ':=' inferred typing.)


## Stamp `to_day` on every OPEN (to_day == -1) relationship of `relationship_type` from `source_npc_id` to
## `target_entity_id`, ending it. Returns {ok, closed: <count>}; closing nothing is a success, not an error,
## because "leave whatever you were in" is the caller's ordinary first step whether or not it was in one.
##
## Matching is on the edge data's stored `target_id` string rather than on a resolved node, so a membership
## can still be closed after the faction node itself has been removed.
static func close_relationship(svc, source_npc_id: String, target_entity_id: String, relationship_type: String, to_day: int) -> Dictionary:
	if source_npc_id.strip_edges() == "":
		return svc._error("invalid_npc_id", "source_npc_id must be non-empty")
	if to_day < 0:
		return svc._error("invalid_to_day", "to_day must be >= 0")
	if not svc._ensure_graph():
		return svc._error("graph_unavailable", "NetworkGraph extension unavailable")
	var source_node: int = svc._node_id_by_external_id(svc.NPC_SPACE, "npc_id", source_npc_id)
	if source_node == -1:
		return svc._error("missing_node", "Relationship source node must exist", {"source_npc_id": source_npc_id})
	var kind: String = relationship_type.to_upper()
	var closed: int = 0
	for edge in svc._graph.get_edges(source_node, svc.DEFAULT_SCAN_LIMIT):
		var row: Dictionary = edge
		if int(row.get("source_id", -1)) != source_node:
			continue
		if String(row.get("kind", "")) != kind:
			continue
		var data: Dictionary = row.get("data", {})
		if String(data.get("target_id", "")) != target_entity_id:
			continue
		if int(data.get("to_day", -1)) != -1:
			continue                                  # already ended
		if int(data.get("from_day", -1)) > to_day:
			continue                                  # would end before it began — leave it open
		var closed_data: Dictionary = data.duplicate(true)
		closed_data["to_day"] = to_day
		var new_edge: int = svc._graph.add_edge(int(row.get("source_id", -1)), int(row.get("target_id", -1)), kind, float(row.get("weight", 1.0)), closed_data)
		if new_edge == -1:
			return svc._error("edge_failed", "Failed to rewrite relationship as closed", {"relationship_type": kind})
		svc._graph.remove_edge(int(row.get("id", -1)))
		closed += 1
	return svc._ok({"closed": closed})


## Every MEMBER_OF record this npc has ever held, open or ended, newest from_day first. Deliberately NOT
## day-windowed: get_backstory_context() already answers "what is true on day N", and the question this
## answers is the other one — what the whole membership history looks like.
static func membership_history(svc, npc_id: String, limit: int = 64) -> Dictionary:
	if npc_id.strip_edges() == "":
		return svc._error("invalid_npc_id", "npc_id must be non-empty")
	if not svc._ensure_graph():
		return svc._error("graph_unavailable", "NetworkGraph extension unavailable")
	var npc_node: int = svc._node_id_by_external_id(svc.NPC_SPACE, "npc_id", npc_id)
	if npc_node == -1:
		return svc._error("missing_npc", "NPC not found", {"npc_id": npc_id})
	var out: Array = []
	for edge in svc._graph.get_edges(npc_node, svc.DEFAULT_SCAN_LIMIT):
		var row: Dictionary = edge
		if int(row.get("source_id", -1)) != npc_node:
			continue
		if String(row.get("kind", "")) != "MEMBER_OF":
			continue
		var data: Dictionary = row.get("data", {})
		out.append({
			"faction_id": String(data.get("target_id", "")),
			"from_day": int(data.get("from_day", -1)),
			"to_day": int(data.get("to_day", -1)),
			"confidence": float(data.get("confidence", row.get("weight", 0.0))),
			"source": String(data.get("source", "")),
			"exclusive": bool(data.get("exclusive", false)),
			"metadata": (data.get("metadata", {}) as Dictionary).duplicate(true),
		})
	out.sort_custom(func(a, b): return int(a.get("from_day", -1)) > int(b.get("from_day", -1)))
	if out.size() > limit:
		out.resize(limit)
	return svc._ok({"npc_id": npc_id, "memberships": out})


## One faction's stored record, or an error when it was never created. The group an animal LEFT has to
## still be there afterwards, and this is what lets a caller check that rather than assume it.
static func get_faction(svc, faction_id: String) -> Dictionary:
	if faction_id.strip_edges() == "":
		return svc._error("invalid_id", "faction id must be non-empty")
	if not svc._ensure_graph():
		return svc._error("graph_unavailable", "NetworkGraph extension unavailable")
	var row: Dictionary = svc._node_by_external_id(svc.FACTION_SPACE, "id", faction_id)
	if row.is_empty():
		return svc._error("missing_faction", "Faction not found", {"id": faction_id})
	return svc._ok({"node_id": int(row.get("id", -1)), "faction": (row.get("data", {}) as Dictionary).duplicate(true)})
