@tool
extends Object
class_name LocalAgentsExtensionLoader

const EXTENSION_PATH := "res://addons/local_agents/gdextensions/localagents/localagents.gdextension"
const RUNTIME_SINGLETON := "AgentRuntime"
const AGENT_NODE_CLASS := "AgentNode"

static var _extension: GDExtension
static var _initialized := false
static var _initializing := false
static var _initialization_error := ""

static func ensure_initialized(force: bool = false) -> bool:
    if _initializing:
        return _initialized
    if _initialized and not force and _extension_initialized():
        return true
    _initializing = true
    _initialization_error = ""
    var resource := load(EXTENSION_PATH)
    if resource == null or not (resource is GDExtension):
        _initialization_error = "Missing localagents extension at %s" % EXTENSION_PATH
        _initializing = false
        return false
    _extension = resource
    var can_initialize := _extension.has_method("initialize")
    if force and can_initialize and _extension_initialized():
        _extension.call("deinitialize")
    if can_initialize and not _extension_initialized():
        var err = _extension.call("initialize")
        if typeof(err) == TYPE_INT and err != OK:
            _initialization_error = "localagents.gdextension initialize() failed with code %s" % err
            _initializing = false
            return false
    _initialized = _extension_initialized()
    if _initialized and not _verify_registration():
        _initialized = false
    _initializing = false
    return _initialized

static func is_initialized() -> bool:
    return _initialized and _extension_initialized()

static func get_error() -> String:
    return _initialization_error

static func deinitialize() -> void:
    if _extension and _extension.has_method("deinitialize") and _extension_initialized():
        _extension.call("deinitialize")
    _extension = null
    _initialized = false
    _initialization_error = ""

static func _extension_initialized() -> bool:
    if _extension == null:
        return false
    if _extension.has_method("is_initialized"):
        return _extension.is_initialized()
    return ClassDB.class_exists(AGENT_NODE_CLASS) and Engine.has_singleton(RUNTIME_SINGLETON)

static func _verify_registration() -> bool:
    if not ClassDB.class_exists(AGENT_NODE_CLASS):
        _initialization_error = "AgentNode class missing after initializing localagents extension"
        return false
    if not Engine.has_singleton(RUNTIME_SINGLETON):
        _initialization_error = "AgentRuntime singleton unavailable after initializing localagents extension"
        return false
    return true
