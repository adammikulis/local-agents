@tool
extends SceneTree

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

func _init() -> void:
    if not ClassDB.class_exists("NetworkGraph"):
        push_error("NetworkGraph class unavailable. Build the GDExtension before running tests.")
        quit()
        return

    _prepare_test_files()

    var service := LocalAgentsProjectGraphService.new()
    var root := get_root()
    if root:
        root.add_child(service)
    service._runtime = MockRuntime.new()

    service.rebuild_project_graph(TEST_DIR, ["gd"])

    var nodes := service.list_code_nodes(64, 0)
    assert(nodes.size() >= 1)

    var search_hits := service.search_code("assistant", 3, 8)
    assert(search_hits.size() >= 1)
    assert(String(search_hits[0].get("path", "")).find("alpha.gd") != -1)

    service.rebuild_project_graph(TEST_DIR, [])
    if service._graph:
        service._graph.close()

    var db_path := ProjectSettings.globalize_path(service.DB_PATH)
    DirAccess.remove_absolute(db_path)

    _cleanup_test_files()
    print("ProjectGraphService tests passed")
    quit()

func _prepare_test_files() -> void:
    if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(TEST_DIR)):
        _cleanup_test_files()
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR))
    var file := FileAccess.open(TEST_DIR.path_join("alpha.gd"), FileAccess.WRITE)
    file.store_string("func alpha():\n    # assistant helper\n    pass\n")
    file.close()

func _cleanup_test_files() -> void:
    if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(TEST_DIR)):
        return
    var dir := DirAccess.open(TEST_DIR)
    if dir:
        dir.list_dir_begin()
        var name := dir.get_next()
        while name != "":
            if dir.current_is_dir():
                dir.remove(name)
            else:
                dir.remove(name)
            name = dir.get_next()
        dir.list_dir_end()
    DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_DIR))
