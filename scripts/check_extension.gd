extends SceneTree

func _init() -> void:
    var loader = preload("res://addons/local_agents/runtime/LocalAgentsExtensionLoader.gd")
    var ok := loader.ensure_initialized()
    if not ok:
        push_error("Extension init failed: %s" % loader.get_error())
        quit(1)
        return
    if not ClassDB.class_exists("AgentNode"):
        push_error("AgentNode missing after init")
        quit(2)
        return
    quit(0)
