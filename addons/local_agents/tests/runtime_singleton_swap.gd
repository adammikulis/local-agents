@tool
extends RefCounted

const ExtensionLoader = preload("res://addons/local_agents/runtime/LocalAgentExtensionLoader.gd")

var _previous: Object = null
var _had_previous: bool = false
var _installed: Object = null

## Register `mock` as the AgentRuntime singleton, remembering what was registered before.
func install(mock: Object) -> void:
	_had_previous = Engine.has_singleton(ExtensionLoader.RUNTIME_SINGLETON)
	_previous = Engine.get_singleton(ExtensionLoader.RUNTIME_SINGLETON) if _had_previous else null
	if _had_previous:
		Engine.unregister_singleton(ExtensionLoader.RUNTIME_SINGLETON)
	_installed = mock
	Engine.register_singleton(ExtensionLoader.RUNTIME_SINGLETON, mock)

## Free the mock and put back whatever was registered before install().
func restore() -> void:
	if _installed == null:
		return
	Engine.unregister_singleton(ExtensionLoader.RUNTIME_SINGLETON)
	_installed.free()
	_installed = null
	if _had_previous:
		Engine.register_singleton(ExtensionLoader.RUNTIME_SINGLETON, _previous)
	_had_previous = false
	_previous = null
