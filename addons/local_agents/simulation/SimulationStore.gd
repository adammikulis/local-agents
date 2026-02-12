extends RefCounted
class_name LocalAgentsSimulationStore

const STORE_DIR = "user://local_agents"
const DB_PATH = STORE_DIR + "/network.sqlite3"
const EVENT_SPACE = "simulation_events"
const CHECKPOINT_SPACE = "simulation_checkpoints"
const RESOURCE_EVENT_SPACE = "simulation_resource_events"

var _graph: Object = null

func open(path: String = "") -> bool:
    if _graph:
        return true
    if not ClassDB.class_exists("NetworkGraph"):
        push_error("NetworkGraph extension unavailable")
        return false
    _graph = ClassDB.instantiate("NetworkGraph")
    if _graph == null:
        push_error("Failed to instantiate NetworkGraph")
        return false
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(STORE_DIR))
    var target_path = path
    if target_path.strip_edges() == "":
        target_path = ProjectSettings.globalize_path(DB_PATH)
    if not _graph.open(target_path):
        push_error("Failed to open simulation store")
        _graph = null
        return false
    return true

func close() -> void:
    if _graph and _graph.has_method("close"):
        _graph.close()
    _graph = null

func begin_event(world_id: String, branch_id: String, tick: int, event_type: String, payload: Dictionary = {}) -> int:
    if not _ensure_graph():
        return -1
    var label = "sim_event:%s:%s:%d:%s" % [world_id, branch_id, tick, event_type]
    return _graph.upsert_node(EVENT_SPACE, label, {
        "type": "sim_event",
        "world_id": world_id,
        "branch_id": branch_id,
        "tick": tick,
        "event_type": event_type,
        "payload": payload.duplicate(true),
        "payload_hash": hash(JSON.stringify(payload, "", false, true)),
    })

func create_checkpoint(world_id: String, branch_id: String, tick: int, state_hash: String, lineage: Array = [], fork_tick: int = -1) -> int:
    if not _ensure_graph():
        return -1
    var label = "sim_checkpoint:%s:%s:%d" % [world_id, branch_id, tick]
    return _graph.upsert_node(CHECKPOINT_SPACE, label, {
        "type": "sim_checkpoint",
        "world_id": world_id,
        "branch_id": branch_id,
        "tick": tick,
        "state_hash": state_hash,
        "lineage": lineage.duplicate(true),
        "fork_tick": fork_tick,
    })

func list_events(world_id: String, branch_id: String, tick_from: int, tick_to: int) -> Array:
    if not _ensure_graph():
        return []
    var rows = _graph.list_nodes(EVENT_SPACE, 65536, 0)
    var items: Array = []
    for row in rows:
        var data: Dictionary = row.get("data", {})
        if String(data.get("world_id", "")) != world_id:
            continue
        if String(data.get("branch_id", "")) != branch_id:
            continue
        var tick = int(data.get("tick", -1))
        if tick < tick_from or tick > tick_to:
            continue
        items.append(data.duplicate(true))
    items.sort_custom(func(a, b):
        var ta = int(a.get("tick", -1))
        var tb = int(b.get("tick", -1))
        if ta == tb:
            return String(a.get("event_type", "")) < String(b.get("event_type", ""))
        return ta < tb
    )
    return items

func append_resource_event(world_id: String, branch_id: String, tick: int, sequence: int, event_type: String, scope: String, owner_id: String, payload: Dictionary = {}) -> int:
    if not _ensure_graph():
        return -1
    if event_type.strip_edges() == "":
        push_error("append_resource_event requires non-empty event_type")
        return -1
    if scope.strip_edges() == "":
        push_error("append_resource_event requires non-empty scope")
        return -1
    var label := "sim_resource:%s:%s:%d:%06d:%s:%s:%s" % [world_id, branch_id, tick, sequence, event_type, scope, owner_id]
    return _graph.upsert_node(RESOURCE_EVENT_SPACE, label, {
        "type": "sim_resource_event",
        "world_id": world_id,
        "branch_id": branch_id,
        "tick": tick,
        "sequence": sequence,
        "event_type": event_type,
        "scope": scope,
        "owner_id": owner_id,
        "payload": payload.duplicate(true),
        "payload_hash": hash(JSON.stringify(payload, "", false, true)),
    })

func list_resource_events(world_id: String, branch_id: String, tick_from: int, tick_to: int) -> Array:
    if not _ensure_graph():
        return []
    var rows = _graph.list_nodes(RESOURCE_EVENT_SPACE, 65536, 0)
    var items: Array = []
    for row in rows:
        var data: Dictionary = row.get("data", {})
        if String(data.get("world_id", "")) != world_id:
            continue
        if String(data.get("branch_id", "")) != branch_id:
            continue
        var tick := int(data.get("tick", -1))
        if tick < tick_from or tick > tick_to:
            continue
        items.append(data.duplicate(true))
    items.sort_custom(func(a, b):
        var ta := int(a.get("tick", -1))
        var tb := int(b.get("tick", -1))
        if ta == tb:
            return int(a.get("sequence", -1)) < int(b.get("sequence", -1))
        return ta < tb
    )
    return items

func _ensure_graph() -> bool:
    return _graph != null or open()
