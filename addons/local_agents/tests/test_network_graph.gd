@tool
extends RefCounted

const TEST_DIR := "user://tests"

func run_test(_tree: SceneTree) -> bool:
    assert(ClassDB.class_exists("NetworkGraph"))

    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR))
    var db_path := TEST_DIR.path_join("network_graph_%d.sqlite3" % Time.get_ticks_msec())
    var graph := NetworkGraph.new()
    assert(graph.open(ProjectSettings.globalize_path(db_path)))

    _test_node_crud(graph)
    _test_edges(graph)
    _test_embeddings(graph)
    var ok: bool = _test_vp_tree_reaches_every_record(graph)

    graph.close()
    DirAccess.remove_absolute(ProjectSettings.globalize_path(db_path))
    if ok:
        print("NetworkGraph tests passed")
    return ok

func _test_node_crud(graph: NetworkGraph) -> void:
    var node_a := graph.upsert_node("demo", "node_a", {"tag": "alpha"})
    assert(node_a != -1)

    var node_a_again := graph.upsert_node("demo", "node_a", {"tag": "beta"})
    assert(node_a == node_a_again)

    var fetched := graph.get_node(node_a)
    assert(not fetched.is_empty())
    assert(fetched.get("id") == node_a)
    assert(fetched.get("data", {}).get("tag") == "beta")

    var nodes := graph.list_nodes("demo", 10, 0)
    assert(nodes.size() == 1)

    var filtered := graph.list_nodes_by_metadata("demo", "tag", "beta", 10, 0)
    assert(filtered.size() == 1)

    var updated := graph.update_node_data(node_a, {"tag": "gamma"})
    assert(updated)
    filtered = graph.list_nodes_by_metadata("demo", "tag", "gamma", 10, 0)
    assert(filtered.size() == 1)

func _test_edges(graph: NetworkGraph) -> void:
    var source := graph.upsert_node("demo", "source", {})
    var target := graph.upsert_node("demo", "target", {})
    var edge_id := graph.add_edge(source, target, "connects", 1.0, {"weight": 0.5})
    assert(edge_id != -1)

    var edges := graph.get_edges(source, 10)
    assert(edges.size() == 1)
    assert(int(edges[0].get("target_id")) == target)

    assert(graph.remove_edge(edge_id))
    edges = graph.get_edges(source, 10)
    assert(edges.is_empty())

func _test_embeddings(graph: NetworkGraph) -> void:
    var a := graph.upsert_node("demo", "emb_a", {})
    var b := graph.upsert_node("demo", "emb_b", {})
    var c := graph.upsert_node("demo", "emb_c", {})

    var vec_a := PackedFloat32Array([1.0, 0.0, 0.0])
    var vec_b := PackedFloat32Array([0.0, 1.0, 0.0])
    var vec_c := PackedFloat32Array([0.0, 0.0, 1.0])

    assert(graph.add_embedding(a, vec_a, {"label": "a"}) != -1)
    assert(graph.add_embedding(b, vec_b, {"label": "b"}) != -1)
    assert(graph.add_embedding(c, vec_c, {"label": "c"}) != -1)

    var query := PackedFloat32Array([1.0, 0.0, 0.0])
    var matches := graph.search_embeddings(query, 3, 3)
    assert(matches.size() >= 1)
    assert(int(matches[0].get("node_id")) == a)
    assert(matches[0].get("metadata", {}).get("label") == "a")

    assert(graph.remove_node(a))
    matches = graph.search_embeddings(query, 3, 3)
    assert(matches.is_empty() or int(matches[0].get("node_id", -1)) != a)

# The vp-tree must reach every record it indexed: a subtree the builder failed to attach is
# unreachable, and the search then answers a top_k it could satisfy with fewer results.
func _test_vp_tree_reaches_every_record(graph: NetworkGraph) -> bool:
    var count: int = 64
    for i in range(count):
        var node_id: int = graph.upsert_node("vp", "vp_%d" % i, {})
        var vector: PackedFloat32Array = PackedFloat32Array([
            float(i + 1),
            float((i * 7) % 13 + 1),
            float((i * 11) % 17 + 1),
        ])
        if graph.add_embedding(node_id, vector, {"label": "vp_%d" % i}) == -1:
            push_error("vp-tree gate: embedding %d rejected" % i)
            return false

    var query: PackedFloat32Array = PackedFloat32Array([1.0, 1.0, 1.0])
    var matches: Array = graph.search_embeddings(query, count, count)
    if matches.size() != count:
        push_error("vp-tree gate: asked for %d nearest, reached %d" % [count, matches.size()])
        return false
    return true
