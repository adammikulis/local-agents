extends RefCounted

const ExtensionLoader = preload("res://addons/local_agents/runtime/LocalAgentExtensionLoader.gd")

## The registered AgentRuntime singleton, or null when the extension has not registered it.
static func singleton() -> Object:
	if not Engine.has_singleton(ExtensionLoader.RUNTIME_SINGLETON):
		return null
	return Engine.get_singleton(ExtensionLoader.RUNTIME_SINGLETON)

## File name of the runtime's default model, or "unknown" when it names none.
static func default_model_name(runtime: Object) -> String:
	if runtime == null:
		return "unknown"
	if runtime.has_method("get_default_model_path"):
		var path: String = String(runtime.call("get_default_model_path")).strip_edges()
		if path != "":
			return path.get_file()
	return "unknown"
