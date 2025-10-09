@tool
extends RefCounted

const TEST_DIR := "res://tmp_project_graph"

class MockRuntime:
    func is_model_loaded() -> bool:
        return true

    func embed_text(text: String, options := {}) -> PackedFloat32Array:
        var normalized := text.to_lower()
        var assistant_score := _substring_count(normalized, "assistant")
        var code_score := _substring_count(normalized, "func")
        var length_score := float(normalized.length()) / 200.0
        return PackedFloat32Array([assistant_score, code_score, length_score])

    func _substring_count(text: String, needle: String) -> float:
        if needle == "":
            return 0.0
        var parts := text.split(needle, false)
        return float(parts.size() - 1)

func run_test(tree: SceneTree) -> bool:
    if not ClassDB.class_exists("NetworkGraph"):
        push_error("NetworkGraph unavailable; build the native extension.")
        return false

    _prepare_test_files()

    var service := LocalAgentsProjectGraphService.new()
    tree.get_root().add_child(service)
    service._runtime = MockRuntime.new()

    service.rebuild_project_graph(TEST_DIR, ["gd"])

    var ok := true
    var nodes := service.list_code_nodes(64, 0)
    ok = ok and _assert(nodes.size() >= 1, "Expected at least one code node")

    var search_hits := service.search_code("assistant", 3, 8)
    ok = ok and _assert(search_hits.size() >= 1, "Search did not return results")

    service.rebuild_project_graph(TEST_DIR, [])
    if service._graph:
        service._graph.close()

    var db_path := ProjectSettings.globalize_path(service.DB_PATH)
    if FileAccess.file_exists(db_path):
        DirAccess.remove_absolute(db_path)

    service.queue_free()
    _cleanup_test_files()
    if ok:
        print("ProjectGraphService tests passed")
    return ok

func _prepare_test_files() -> void:
    var abs := ProjectSettings.globalize_path(TEST_DIR)
    if DirAccess.dir_exists_absolute(abs):
        _cleanup_test_files()
    DirAccess.make_dir_recursive_absolute(abs)
    var file := FileAccess.open(TEST_DIR.path_join("alpha.gd"), FileAccess.WRITE)
    file.store_string("func alpha():\n    # assistant helper\n    pass\n")
    file.close()

func _cleanup_test_files() -> void:
    var abs := ProjectSettings.globalize_path(TEST_DIR)
    if not DirAccess.dir_exists_absolute(abs):
        return
    var dir := DirAccess.open(TEST_DIR)
    if dir:
        dir.list_dir_begin()
        var name := dir.get_next()
        while name != "":
            var entry_path := TEST_DIR.path_join(name)
            DirAccess.remove_absolute(ProjectSettings.globalize_path(entry_path))
            name = dir.get_next()
        dir.list_dir_end()
    DirAccess.remove_absolute(abs)

func _assert(condition: bool, message: String) -> bool:
    if not condition:
        push_error(message)
    return condition
