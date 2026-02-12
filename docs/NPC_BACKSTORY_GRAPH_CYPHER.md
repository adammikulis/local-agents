# NPC Backstory Graph and Cypher Mapping

This document defines a concrete graph schema for NPC memory, quests, dialogue state, and world time, then maps it to the current local `NetworkGraph` runtime (`addons/local_agents/gdextensions/localagents/src/NetworkGraph.cpp`).

## 1. Canonical Graph Schema (Cypher-first)

Note: this project runtime is `NetworkGraph` (C++ + SQLite). Neo4j/Cypher usage is optional and external for analysis, validation, or migration.

### Node labels and required properties

| Label | Required properties | Notes |
|---|---|---|
| `NPC` | `npc_id`, `name`, `faction` | One node per NPC. |
| `Memory` | `memory_id`, `kind`, `summary`, `importance`, `created_at` | `kind` example: `backstory`, `interaction`, `rumor`. |
| `Quest` | `quest_id`, `title`, `status`, `priority`, `created_at` | `status`: `active`, `blocked`, `completed`, `failed`. |
| `DialogueState` | `state_id`, `topic`, `mood`, `last_updated_at` | Fine-grained per NPC/topic state. |
| `WorldTime` | `time_id`, `tick`, `day`, `hour`, `calendar` | Usually one current node plus history snapshots. |

### Relationship types

| Type | Direction | Required properties | Meaning |
|---|---|---|---|
| `REMEMBERS` | `(:NPC)-[:REMEMBERS]->(:Memory)` | `strength`, `last_recalled_at` | NPC owns memory. |
| `UNLOCKS` | `(:Memory)-[:UNLOCKS]->(:Quest)` | `condition`, `created_at` | Memory can unlock quest. |
| `OFFERS` | `(:NPC)-[:OFFERS]->(:Quest)` | `role` | NPC offers/owns questline role. |
| `HAS_DIALOGUE_STATE` | `(:NPC)-[:HAS_DIALOGUE_STATE]->(:DialogueState)` | `topic` | NPC state per topic. |
| `REFERS_TO` | `(:DialogueState)-[:REFERS_TO]->(:Memory)` | `weight` | Dialogue can pull from memory. |
| `CURRENT_TIME` | `(:WorldTime)-[:CURRENT_TIME]->(:WorldTime)` | none | Optional self-link for current pointer style. |
| `ACTIVE_AT` | `(:Quest)-[:ACTIVE_AT]->(:WorldTime)` | `start_tick`, `end_tick` | Quest availability window. |

## 2. Cypher Constraints (Neo4j)

```cypher
CREATE CONSTRAINT npc_id_unique IF NOT EXISTS
FOR (n:NPC) REQUIRE n.npc_id IS UNIQUE;

CREATE CONSTRAINT memory_id_unique IF NOT EXISTS
FOR (m:Memory) REQUIRE m.memory_id IS UNIQUE;

CREATE CONSTRAINT quest_id_unique IF NOT EXISTS
FOR (q:Quest) REQUIRE q.quest_id IS UNIQUE;

CREATE CONSTRAINT dialogue_state_id_unique IF NOT EXISTS
FOR (d:DialogueState) REQUIRE d.state_id IS UNIQUE;

CREATE CONSTRAINT world_time_id_unique IF NOT EXISTS
FOR (t:WorldTime) REQUIRE t.time_id IS UNIQUE;

CREATE INDEX quest_status_idx IF NOT EXISTS
FOR (q:Quest) ON (q.status);

CREATE INDEX memory_kind_created_idx IF NOT EXISTS
FOR (m:Memory) ON (m.kind, m.created_at);
```

## 3. Practical Cypher Query Recipes

### Upsert NPC + backstory memory and connect

```cypher
MERGE (n:NPC {npc_id: $npc_id})
ON CREATE SET n.name = $name, n.faction = $faction
ON MATCH SET n.name = $name, n.faction = $faction

MERGE (m:Memory {memory_id: $memory_id})
SET m.kind = 'backstory',
    m.summary = $summary,
    m.importance = $importance,
    m.created_at = $created_at

MERGE (n)-[r:REMEMBERS]->(m)
SET r.strength = $strength,
    r.last_recalled_at = $created_at;
```

### Active quests for one NPC at world tick

```cypher
MATCH (n:NPC {npc_id: $npc_id})-[:OFFERS]->(q:Quest)-[a:ACTIVE_AT]->(t:WorldTime)
WHERE q.status = 'active'
  AND a.start_tick <= $tick
  AND ($tick <= a.end_tick OR a.end_tick IS NULL)
RETURN q.quest_id, q.title, q.priority
ORDER BY q.priority DESC, q.created_at ASC;
```

### Dialogue memory recall candidates

```cypher
MATCH (n:NPC {npc_id: $npc_id})-[:HAS_DIALOGUE_STATE]->(d:DialogueState {topic: $topic})
OPTIONAL MATCH (d)-[r:REFERS_TO]->(m:Memory)
RETURN d.state_id, d.mood, m.memory_id, m.summary, m.importance, r.weight
ORDER BY r.weight DESC, m.importance DESC
LIMIT $k;
```

### Transition quest status from world time

```cypher
MATCH (q:Quest)-[a:ACTIVE_AT]->(:WorldTime)
WHERE q.status = 'active'
  AND a.end_tick IS NOT NULL
  AND a.end_tick < $tick
SET q.status = 'failed',
    q.closed_at = timestamp()
RETURN count(q) AS transitioned;
```

## 4. Mapping to Current Local `NetworkGraph`

Current store supports:
- `nodes(space, label, data)` with `UNIQUE(space, label)`.
- `edges(source_id, target_id, kind, weight, data)`.
- `embeddings(node_id, vector, metadata)`.

It does not execute Cypher directly. Use this mapping:

### Node mapping

| Cypher label | `space` | `label` (must be stable) | `data` keys |
|---|---|---|---|
| `NPC` | `npc` | `npc:<npc_id>` | `type='npc'`, `npc_id`, `name`, `faction` |
| `Memory` | `npc_memory` | `memory:<memory_id>` | `type='memory'`, `memory_id`, `npc_id`, `kind`, `summary`, `importance`, `created_at` |
| `Quest` | `quest` | `quest:<quest_id>` | `type='quest'`, `quest_id`, `title`, `status`, `priority`, `created_at`, `owner_npc_id` |
| `DialogueState` | `dialogue_state` | `dialogue_state:<npc_id>:<topic>` | `type='dialogue_state'`, `state_id`, `npc_id`, `topic`, `mood`, `last_updated_at` |
| `WorldTime` | `world_time` | `world_time:<tick>` | `type='world_time'`, `time_id`, `tick`, `day`, `hour`, `calendar`, `is_current` |

### Edge mapping

| Cypher relationship | `kind` | `data` keys |
|---|---|---|
| `REMEMBERS` | `remembers` | `type='remembers'`, `npc_id`, `memory_id`, `strength`, `last_recalled_at` |
| `UNLOCKS` | `unlocks` | `type='unlocks'`, `condition`, `created_at` |
| `OFFERS` | `offers` | `type='offers'`, `role` |
| `HAS_DIALOGUE_STATE` | `has_dialogue_state` | `type='has_dialogue_state'`, `topic` |
| `REFERS_TO` | `refers_to` | `type='refers_to'`, `weight` |
| `ACTIVE_AT` | `active_at` | `type='active_at'`, `start_tick`, `end_tick` |

### Why this works with current constraints

- Domain uniqueness is enforced by deterministic `label` values because runtime uniqueness is `(space, label)`.
- Cypher `MERGE` maps to `upsert_node(space, label, data)`.
- Relationship insertion maps to `add_edge(source_id, target_id, kind, weight, data)`.

## 5. Implementation Patterns in GDScript

### Upsert NPC and memory (`MERGE` equivalent)

```gdscript
var npc_id: int = graph.upsert_node("npc", "npc:%s" % npc_key, {
    "type": "npc",
    "npc_id": npc_key,
    "name": name,
    "faction": faction,
})

var memory_node_id: int = graph.upsert_node("npc_memory", "memory:%s" % memory_key, {
    "type": "memory",
    "memory_id": memory_key,
    "npc_id": npc_key,
    "kind": "backstory",
    "summary": summary,
    "importance": importance,
    "created_at": Time.get_unix_time_from_system(),
})

graph.add_edge(npc_id, memory_node_id, "remembers", importance, {
    "type": "remembers",
    "npc_id": npc_key,
    "memory_id": memory_key,
    "strength": importance,
    "last_recalled_at": Time.get_unix_time_from_system(),
})
```

### Query active quests (current API composition)

```gdscript
# 1) Resolve NPC node.
var npc_rows: Array = graph.list_nodes_by_metadata("npc", "npc_id", npc_key, 1, 0)
if npc_rows.is_empty():
    return []
var npc_node_id := int(npc_rows[0].get("id", -1))

# 2) Walk OFFERS edges from NPC.
var edges: Array = graph.get_edges(npc_node_id, 4096)
var active: Array = []
for edge in edges:
    if int(edge.get("source_id", -1)) != npc_node_id:
        continue
    if String(edge.get("kind", "")) != "offers":
        continue

    var quest := graph.get_node(int(edge.get("target_id", -1)))
    var qd: Dictionary = quest.get("data", {})
    if String(qd.get("status", "")) != "active":
        continue

    # Evaluate ACTIVE_AT edge window.
    var quest_edges: Array = graph.get_edges(int(quest.get("id", -1)), 128)
    for qe in quest_edges:
        if int(qe.get("source_id", -1)) != int(quest.get("id", -1)):
            continue
        if String(qe.get("kind", "")) != "active_at":
            continue
        var ad: Dictionary = qe.get("data", {})
        var start_tick := int(ad.get("start_tick", 0))
        var end_tick := int(ad.get("end_tick", -1))
        if tick >= start_tick and (end_tick == -1 or tick <= end_tick):
            active.append(qd)
            break
```

## 6. Vector Recall for Backstory Memory

Add memory embeddings exactly as conversation embeddings are added today:

```gdscript
var emb := runtime.call("embed_text", summary, {"normalize": true})
if not emb.is_empty():
    graph.add_embedding(memory_node_id, emb, {
        "type": "npc_memory",
        "npc_id": npc_key,
        "memory_id": memory_key,
        "kind": "backstory",
    })
```

Then query with `search_embeddings` and hydrate with `get_node(node_id)`.

## 7. Current Limits and Guardrails

- No multi-hop query API: perform graph traversals in GDScript (`get_edges` + `get_node`).
- No relationship uniqueness: callers should dedupe before `add_edge` when idempotency matters.
- `list_nodes_by_metadata` supports top-level JSON equality only (`$.key = value`).
- Time windows (`start_tick`/`end_tick`) are evaluated in application code today.

## 8. Relationship Model (Long-term vs Recent)

Use directional relationship profiles per pair (`source_npc_id -> target_npc_id`) with independent tags:
- `family` can coexist with `friend` and/or `enemy`.
- Recent interactions should dominate long-term feelings.

Implemented local spaces:
- `relationship_profile`: stable per NPC pair, stores tags + long-term values (`bond`, `trust`, `respect`).
- `relationship_event`: interaction log with deltas (`valence_delta`, `trust_delta`, `respect_delta`).

Long-term update rule used in runtime:
- Compute recent-window averages from `relationship_event` (default 14 days).
- Blend into long-term with high recent weight (`recent_weight = 0.85`):
  - `long_term = previous * 0.15 + recent_avg * 0.85`
- This makes current behavior the main influencer while preserving a small memory tail.

Cypher equivalent concept:

```cypher
MATCH (a:NPC {npc_id: $source})-[:INTERACTED_WITH]->(e:InteractionEvent)-[:AFFECTS]->(b:NPC {npc_id: $target})
WHERE e.world_day >= $world_day - $window_days AND e.world_day <= $world_day
WITH avg(e.valence_delta) AS recent_bond, avg(e.trust_delta) AS recent_trust, avg(e.respect_delta) AS recent_respect
MATCH (a)-[r:RELATES_TO]->(b)
SET r.long_bond = coalesce(r.long_bond, 0.0) * 0.15 + recent_bond * 0.85,
    r.long_trust = coalesce(r.long_trust, 0.0) * 0.15 + recent_trust * 0.85,
    r.long_respect = coalesce(r.long_respect, 0.0) * 0.15 + recent_respect * 0.85;
```

Use this document as the schema contract for NPC/quest/dialogue/time features until a direct Cypher backend is introduced.

## 9. Operational Cypher Pack (Recommended)

`LocalAgentsBackstoryGraphService.get_cypher_playbook(npc_id, world_day, limit)` now returns a query catalog you can feed into optional external Neo4j analysis tools (for example Neo4j Browser/Cypher Shell). It is not executed by the in-engine runtime backend.

Suggested high-value queries from the playbook:

### NPC backstory context

Use when building LLM prompt context for one NPC.

```cypher
MATCH (n:NPC {npc_id: $npc_id})
OPTIONAL MATCH (n)-[rel]->(x)
WHERE (
    x:Memory OR
    x:QuestState OR
    x:DialogueState OR
    x:RelationshipProfile OR
    type(rel) IN ['HAS_MEMORY', 'HAS_QUEST_STATE', 'HAS_DIALOGUE_STATE', 'HAS_RELATIONSHIP_PROFILE']
)
RETURN n, rel, x
ORDER BY coalesce(x.world_day, 0) DESC, coalesce(x.updated_at, 0) DESC
LIMIT $limit;
```

### Exclusive membership conflicts

Use for writer QA and contradiction checks.

```cypher
MATCH (n:NPC)-[m:MEMBER_OF]->(f:Faction)
WHERE coalesce(m.exclusive, false) = true AND coalesce(m.to_day, -1) = -1
WITH n, collect(f.faction_id) AS factions, count(m) AS cnt
WHERE cnt > 1
RETURN n.npc_id AS npc_id, factions, cnt
ORDER BY cnt DESC
LIMIT $limit;
```

### Post-death quest activity

Use to detect timeline inconsistency after death state is set.

```cypher
MATCH (n:NPC {npc_id: $npc_id})-[:HAS_DIALOGUE_STATE]->(life:DialogueState {state_key: 'life_status'})
MATCH (n)-[:HAS_DIALOGUE_STATE]->(death:DialogueState {state_key: 'death_day'})
MATCH (n)-[:HAS_QUEST_STATE]->(qs:QuestState)
WHERE life.state_value = 'dead' AND qs.world_day > toInteger(death.state_value)
RETURN n.npc_id AS npc_id,
       toInteger(death.state_value) AS death_day,
       qs.quest_id AS quest_id,
       qs.state AS quest_state,
       qs.world_day AS world_day
ORDER BY qs.world_day ASC
LIMIT $limit;
```

### Relationship state aggregate

Use to combine long-term profile with recent interaction drift.

```cypher
MATCH (a:NPC {npc_id: $source_npc_id})
MATCH (b:NPC {npc_id: $target_npc_id})
OPTIONAL MATCH (a)-[:HAS_RELATIONSHIP_PROFILE]->(p:RelationshipProfile)-[:TARGETS_NPC]->(b)
OPTIONAL MATCH (e:RelationshipEvent {source_npc_id: $source_npc_id, target_npc_id: $target_npc_id})
WHERE e.world_day >= $window_start AND e.world_day <= $world_day
RETURN p,
       count(e) AS recent_count,
       avg(e.valence_delta) AS recent_valence_avg,
       avg(e.trust_delta) AS recent_trust_avg,
       avg(e.respect_delta) AS recent_respect_avg;
```
