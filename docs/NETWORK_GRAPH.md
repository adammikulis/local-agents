# NetworkGraph Integration

The Local Agents data layer now persists conversational memory and project knowledge in a single SQLite database (`user://local_agents/network.sqlite3`). A native `NetworkGraph` class (GDExtension) wraps the database and exposes ergonomic methods for GDScript.

## Schema Overview

| Table        | Purpose                                              |
|--------------|------------------------------------------------------|
| `nodes`      | Graph vertices grouped by `space` (conversation, code, etc.). Metadata is stored as JSON for flexible filtering.
| `edges`      | Directed links between nodes with optional weights and metadata.
| `embeddings` | Vector store aligned with nodes. Each row stores the float vector, L2 norm, JSON metadata, and timestamps.

The database enables cascading deletes, WAL mode, and JSON1/FTS5 extensions for future indexing work.

## GDExtension API Highlights

```gdscript
var graph := NetworkGraph.new()
if graph.open(ProjectSettings.globalize_path("user://local_agents/network.sqlite3")):
    var node_id := graph.upsert_node("conversation", "conversation_001", {
        "title": "Session",
        "created_at": Time.get_unix_time_from_system(),
    })
    graph.add_edge(node_id, other_id, "contains", 1.0, {"order": 1})
    var matches := graph.search_embeddings(embedding_vector, 5, 32)
```

- `list_nodes(space, limit, offset)` and `list_nodes_by_metadata(space, key, value, limit, offset)` support pagination and JSON querying.
- `add_embedding(node_id, vector, metadata)` stores normalized vectors and keeps the ANN index in sync.
- `search_embeddings(query_vector, top_k, expand)` performs VP-tree search and returns `{embedding_id, node_id, distance, similarity, metadata}` dictionaries.

## Conversation Store

`LocalAgentsConversationStore` fronts the SQLite store. It:

- Creates conversations and messages as graph nodes.
- Maintains `contains` and `sequence` edges for traversal.
- Calls `AgentRuntime.embed_text()` to create embeddings for each message (if a llama.cpp model is loaded).
- Exposes `search_messages(query, top_k, expand)` for quick memory recall in UI or agent prompts.

## Project Graph Service

`addons/local_agents/graph/ProjectGraphService.gd` scans project folders and maps them into the graph:

```gdscript
var service := LocalAgentsProjectGraphService.new()
service.rebuild_project_graph("res://", ["gd", "tscn"])
var hits := service.search_code("dialogue manager", 5)
```

Each file node carries metadata (`path`, `extension`, hashes) and optional embeddings. Directory nodes live in the `code_dir` space and link back to file nodes for hierarchy queries.

## Embedding Pipeline

`AgentRuntime.embed_text(text, options := {})` reuses the currently loaded llama.cpp model to generate normalized embeddings. The runtime always enables the llama context `embeddings` flag, so a single model load supports both chat generation and vector extraction. Options include:

- `add_bos` (default `true`): prepend BOS when tokenising.
- `normalize` (default `true`): return unit-length vectors for cosine similarity workflows.

## Next Steps

1. **Memory surfaces in the Editor** – wire search results into the planned Memory and Graph tabs to make debugging easy.
2. **Streaming embeddings** – batch message/code ingestion so large projects can be indexed without blocking the main thread.
3. **Advanced ANN structures** – persist HNSW layer data inside SQLite once dataset sizes grow beyond a few thousand nodes.
4. **Temporal queries** – add helper methods for retrieving conversation windows by timestamp or tag.
