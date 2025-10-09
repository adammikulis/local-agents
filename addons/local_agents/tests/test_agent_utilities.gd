@tool
extends RefCounted

func run_test(_tree: SceneTree) -> bool:
    var agent := LocalAgentsAgent.new()
    var ok := true

    ok = ok and _assert(agent._normalize_path("") == "", "Empty path normalization failed")

    var res_path := "res://addons/local_agents/plugin.cfg"
    var res_abs := ProjectSettings.globalize_path(res_path)
    ok = ok and _assert(agent._normalize_path(res_path) == res_abs, "Resource normalization mismatch")

    var user_path := "user://local_agents/tests/sample.txt"
    var user_abs := ProjectSettings.globalize_path(user_path)
    ok = ok and _assert(agent._normalize_path(user_path) == user_abs, "User normalization mismatch")

    var absolute_path := "/tmp/local_agents_demo"
    ok = ok and _assert(agent._normalize_path(absolute_path) == absolute_path, "Absolute normalization mismatch")

    ok = ok and _assert(not agent._is_absolute_path("relative/path"), "Relative path detected as absolute")
    ok = ok and _assert(agent._is_absolute_path("/absolute"), "Absolute POSIX path not detected")
    ok = ok and _assert(agent._is_absolute_path("C:\\demo"), "Absolute Windows path not detected")

    var tts_abs := ProjectSettings.globalize_path("user://local_agents/tts")
    _clear_directory(tts_abs)
    agent.queue_free()

    var first := agent._allocate_tts_path()
    var second := agent._allocate_tts_path()

    ok = ok and _assert(first != "", "First TTS allocation empty")
    ok = ok and _assert(second != "", "Second TTS allocation empty")

    var tts_dir_abs := ProjectSettings.globalize_path("user://local_agents/tts")
    ok = ok and _assert(DirAccess.dir_exists_absolute(tts_dir_abs), "TTS directory not created")

    _clear_directory(tts_abs)
    if ok:
        print("Local Agents utility tests passed")
    return ok

func _assert(condition: bool, message: String) -> bool:
    if not condition:
        push_error(message)
    return condition

func _clear_directory(path_abs: String) -> void:
    if not DirAccess.dir_exists_absolute(path_abs):
        return
    var dir := DirAccess.open(path_abs)
    if dir == null:
        return
    dir.list_dir_begin()
    var entry := dir.get_next()
    while entry != "":
        if entry == "." or entry == "..":
            entry = dir.get_next()
            continue
        var entry_path := path_abs.path_join(entry)
        if dir.current_is_dir():
            _clear_directory(entry_path)
        DirAccess.remove_absolute(entry_path)
        entry = dir.get_next()
    dir.list_dir_end()
