# API: the memory graph

Part of the [API reference](API.md).

## The memory graph

### LocalAgentGraph

`addons/local_agents/graph/Graph.gd`, extends `Resource`.

A directed graph of typed nodes and weighted edges. `LocalAgent` writes its conversation into one when you assign it to Memory
Graph, and `LocalAgentConversation` records one utterance per node. It is an ordinary Resource, so you can save it as a `.tres`,
hand the same instance to several agents to give them a shared record, or build one yourself.

Ids are assigned by the graph. `ensure_id_counters()` rescans `nodes` and `edges` for the highest id in use and numbers from one
past it, which is what makes a graph loaded from disk continue correctly. `add_node()` and `add_edge()` call it first, so you rarely
call it yourself. Note that ids are therefore reusable: remove the highest-numbered node and the next one added takes that id back.

#### Exports
- `nodes` (Array[LocalAgentGraphNode], default `[]`).
- `edges` (Array[LocalAgentGraphEdge], default `[]`).

#### Methods
```gdscript
func ensure_id_counters() -> void
func add_node(name: String = "", data: Dictionary = {}) -> LocalAgentGraphNode
func remove_node(node_id: int) -> bool
func add_edge(source_id: int, target_id: int, name: String = "", weight: float = 1.0, data: Dictionary = {}, is_bidirectional: bool = false) -> LocalAgentGraphEdge
func remove_edge(edge_id: int) -> bool
func get_node(node_id: int) -> LocalAgentGraphNode
func get_edge(edge_id: int) -> LocalAgentGraphEdge
func get_edges() -> Array[LocalAgentGraphEdge]
func update_edge_weight(edge_id: int, amount: float) -> void
func update_all_edge_weights(amount: float) -> void
```

`remove_node()` also removes every edge touching that node, and returns false when the id is not found. `add_edge()` pushes an error
and returns null when either endpoint does not exist, and with `is_bidirectional` true it also appends a reverse edge with its own
id sharing the same name, weight and data, while still returning the forward one. `update_edge_weight()` and
`update_all_edge_weights()` add `amount` to the weight, so pass a negative number to decay.

`get_node()` and `get_edge()` are linear scans, and so is every id lookup underneath the mutators. That is fine for a conversation
and wrong for a graph of thousands of nodes.

### LocalAgentGraphNode

`addons/local_agents/graph/GraphNode.gd`, extends `Resource`.

- `id` (int, default `0`). Assigned by the graph.
- `name` (String, default `""`). In a conversation graph this is the speaker or the role.
- `data` (Dictionary, default `{}`). Deep-copied on construction.

```gdscript
func _init(p_id: int = 0, p_name: String = "", p_data: Dictionary = {})
```

`LocalAgentConversation` writes `{"turn": int, "said": String}` into `data`.

### LocalAgentGraphEdge

`addons/local_agents/graph/GraphEdge.gd`, extends `Resource`.

- `id` (int, default `0`). Assigned by the graph.
- `source_id` (int, default `0`), `target_id` (int, default `0`).
- `name` (String, default `""`). The relation. Conversation edges are named `then` by default.
- `weight` (float, default `1.0`).
- `data` (Dictionary, default `{}`). Deep-copied on construction.

```gdscript
func _init(p_id: int = 0, p_source: int = 0, p_target: int = 0, p_name: String = "", p_weight: float = 1.0, p_data: Dictionary = {})
func update_weight(amount: float) -> void
```

`update_weight()` adds `amount` to the current weight rather than replacing it.

### LocalAgentGraphRule

`addons/local_agents/graph/GraphRule.gd`, extends `Resource`.

A condition plus a threshold, for driving graph changes from a predicate.

- `condition` (Callable, default `Callable()`). Called as `condition.call(variable, delta)` and expected to return an Array whose
  first two entries are a string and a bool.
- `memory_threshold` (float, default `0.0`).

```gdscript
func _init(p_condition: Callable = Callable(), p_threshold: float = 0.0)
func evaluate(variable: String, delta: float) -> Array
```

`evaluate()` returns `["", false]` when the Callable is invalid or when the result is not an Array of at least two entries.
Otherwise it returns `[str(result[0]), bool(result[1])]`.

A Callable does not serialise on a Resource, so a rule saved to a `.tres` loses its condition. Build these in code.

### LocalAgentBackstoryGraphService

`addons/local_agents/graph/BackstoryGraphService.gd`, extends `Node`.

The long memory. `LocalAgentGraph` above records what was said; this records what a character *knows*, and recalls the
relevant parts of it. Add it to the scene, assign it to `LocalAgent`'s **Backstory** slot, and give the agent an `npc_id`.
Every line in and out is then ingested, and the most relevant memories are recalled into a system message ahead of each
prompt. Recall is opt-in per agent (`recall_memories`, off by default), so a game that never asked for it pays nothing.

Storage is SQLite through the `NetworkGraph` GDExtension, at `user://local_agents/network.sqlite3` by default. No model is
required for anything except semantic recall: with no llama-server running, recall falls back to recent-and-important
memories rather than failing.

```gdscript
func set_database_path(path: String) -> void
```

Points the store at a different database file. Honoured whenever you call it — if the graph is already open on another
path it is closed and reopened — so it is safe before or after `add_child()`.

Beyond the conversation memory `LocalAgent` wires for you, the service exposes about forty calls for building a
character's world: `upsert_npc`, `upsert_faction`, `upsert_place`, `upsert_quest`, `set_world_time`, `add_relationship`
(dated membership and inter-entity links), `record_event`, `add_memory`, `record_oral_knowledge` and
`link_oral_knowledge_lineage` (knowledge passing between characters with provenance and hop counts), `upsert_world_truth`
versus `upsert_npc_belief` with `get_belief_truth_conflicts` (a character can believe something the world contradicts),
`update_quest_state`, and `search_memory_embeddings`. Each returns `{"ok": true, ...}` or
`{"ok": false, "error": {"code", "message", "details"}}`.

Dated calls take a `world_day` integer. `-1` means undated and is accepted by memories, truths, beliefs and knowledge;
`add_relationship`, `update_quest_state`, `record_relationship_interaction` and `set_world_time` require `>= 0`.

The signatures are one line each and grouped by area in the source; read it there for the full list.

---

[Back to the API reference index](API.md)
