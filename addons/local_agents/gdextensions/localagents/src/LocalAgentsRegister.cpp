#include <godot_cpp/godot.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include "AgentNode.hpp"
#include "AgentRuntime.hpp"

using namespace godot;

namespace {
AgentRuntime *g_agent_runtime_singleton = nullptr;
}

extern "C" {

GDExtensionBool GDE_EXPORT localagents_library_init(const GDExtensionInterface *p_interface,
                                                     GDExtensionClassLibraryPtr p_library,
                                                     GDExtensionInitialization *r_initialization) {
    GDExtensionBinding::InitObject init_obj(p_interface, p_library, r_initialization);

    init_obj.register_initializer([]() {
        ClassDB::register_class<AgentRuntime>();
        ClassDB::register_class<AgentNode>();
        if (!g_agent_runtime_singleton) {
            g_agent_runtime_singleton = memnew(AgentRuntime);
            g_agent_runtime_singleton->set_name("AgentRuntime");
            Engine::get_singleton()->register_singleton(StringName("AgentRuntime"), g_agent_runtime_singleton);
        }
    });

    init_obj.register_terminator([]() {
        if (g_agent_runtime_singleton) {
            Engine::get_singleton()->unregister_singleton(StringName("AgentRuntime"));
            memdelete(g_agent_runtime_singleton);
            g_agent_runtime_singleton = nullptr;
        }
    });

    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

    return init_obj.init();
}

}
