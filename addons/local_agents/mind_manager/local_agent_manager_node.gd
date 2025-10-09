@tool
extends Node
class_name LocalAgentManagerNode

var _model_path: String = ""
var _manager_cache: LocalAgentManager
var _is_syncing: bool = false

@export_file("*") var model_path: String = "":
    set(value):
        if value == _model_path:
            return
        _model_path = value
        if _is_syncing:
            return
        if _should_auto_apply():
            _apply_model_path()
    get:
        return _model_path

@export var auto_apply_on_ready: bool = true
@export var apply_in_editor: bool = true

func _enter_tree() -> void:
    var manager := _get_manager()
    if manager:
        var callable := Callable(self, "_on_manager_model_changed")
        if not manager.model_changed.is_connected(callable):
            manager.model_changed.connect(callable)
        if auto_apply_on_ready:
            if _model_path.strip_edges().is_empty():
                _sync_from_manager()
            else:
                _apply_model_path()
        else:
            _sync_from_manager()
    elif auto_apply_on_ready:
        _apply_model_path()

func _exit_tree() -> void:
    var manager := _get_manager()
    if manager:
        var callable := Callable(self, "_on_manager_model_changed")
        if manager.model_changed.is_connected(callable):
            manager.model_changed.disconnect(callable)
    _manager_cache = null

func _should_auto_apply() -> bool:
    if Engine.is_editor_hint():
        return apply_in_editor and _manager_available()
    return _manager_available()

func apply_model_path() -> void:
    _apply_model_path()

func sync_from_singleton() -> void:
    _sync_from_manager()

func _apply_model_path() -> void:
    var manager := _get_manager()
    if not manager:
        return
    if _model_path.strip_edges().is_empty():
        manager.unload_model()
    else:
        manager.set_model_path(_model_path)

func _sync_from_manager() -> void:
    var manager := _get_manager()
    if not manager:
        return
    if manager.model_path == _model_path:
        return
    _is_syncing = true
    model_path = manager.model_path
    _is_syncing = false

func _on_manager_model_changed(path: String) -> void:
    if path == _model_path:
        return
    _is_syncing = true
    model_path = path
    _is_syncing = false

func _manager_available() -> bool:
    return _get_manager() != null

func _get_manager() -> LocalAgentManager:
    if _manager_cache and is_instance_valid(_manager_cache):
        return _manager_cache
    if Engine.has_singleton("LocalAgentManager"):
        var singleton := Engine.get_singleton("LocalAgentManager")
        if singleton is LocalAgentManager:
            _manager_cache = singleton
            return _manager_cache
    if is_inside_tree():
        var root := get_tree().root
        var node := root.get_node_or_null("LocalAgentManager")
        if node is LocalAgentManager:
            _manager_cache = node
            return _manager_cache
    return null
