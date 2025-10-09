@tool
extends SceneTree

func _init() -> void:
    var agent := LocalAgentsAgent.new()

    assert(agent._normalize_path("") == "")

    var res_path := "res://addons/local_agents/plugin.cfg"
    var res_abs := ProjectSettings.globalize_path(res_path)
    assert(agent._normalize_path(res_path) == res_abs)

    var user_path := "user://local_agents/tests/sample.txt"
    var user_abs := ProjectSettings.globalize_path(user_path)
    assert(agent._normalize_path(user_path) == user_abs)

    var absolute_path := "/tmp/local_agents_demo"
    assert(agent._normalize_path(absolute_path) == absolute_path)

    assert(not agent._is_absolute_path("relative/path"))
    assert(agent._is_absolute_path("/absolute"))
    assert(agent._is_absolute_path("C:\\demo"))

    var tts_abs := ProjectSettings.globalize_path("user://local_agents/tts")
    _clear_directory(tts_abs)

    var first := agent._allocate_tts_path()
    OS.delay_msec(5)
    var second := agent._allocate_tts_path()

    assert(first != "")
    assert(second != "")
    assert(first != second)

    var tts_dir_abs := ProjectSettings.globalize_path("user://local_agents/tts")
    assert(DirAccess.dir_exists_absolute(tts_dir_abs))

    print("Local Agents utility tests passed")
    quit()

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
        else:
            DirAccess.remove_absolute(entry_path)
        entry = dir.get_next()
    dir.list_dir_end()
