#include <godot_cpp/godot.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include "AgentNode.hpp"
#include "AgentRuntime.hpp"
#include "LocalAgentsSimulationCore.hpp"
#include "LocalAgentsNativeVoxelTerrainMutator.hpp"
#include "NetworkGraph.hpp"

using namespace godot;

namespace {
AgentRuntime *g_agent_runtime_singleton = nullptr;
LocalAgentsSimulationCore *g_simulation_core_singleton = nullptr;

void initialize_local_agents(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }

    ClassDB::register_class<AgentRuntime>();
    ClassDB::register_class<AgentNode>();
    ClassDB::register_class<NetworkGraph>();
    ClassDB::register_class<LocalAgentsSimulationCore>();
    ClassDB::register_class<LocalAgentsNativeVoxelTerrainMutator>();

    if (!g_agent_runtime_singleton) {
        g_agent_runtime_singleton = memnew(AgentRuntime);
        g_agent_runtime_singleton->set_name("AgentRuntime");
        Engine::get_singleton()->register_singleton(StringName("AgentRuntime"), g_agent_runtime_singleton);
    }
    if (!g_simulation_core_singleton) {
        g_simulation_core_singleton = memnew(LocalAgentsSimulationCore);
        Engine::get_singleton()->register_singleton(StringName("LocalAgentsSimulationCore"), g_simulation_core_singleton);
    }
}

void terminate_local_agents(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }

    if (g_agent_runtime_singleton) {
        Engine::get_singleton()->unregister_singleton(StringName("AgentRuntime"));
        memdelete(g_agent_runtime_singleton);
        g_agent_runtime_singleton = nullptr;
    }
    if (g_simulation_core_singleton) {
        Engine::get_singleton()->unregister_singleton(StringName("LocalAgentsSimulationCore"));
        memdelete(g_simulation_core_singleton);
        g_simulation_core_singleton = nullptr;
    }
}
}

extern "C" {

GDExtensionBool GDE_EXPORT localagents_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
                                                     GDExtensionClassLibraryPtr p_library,
                                                     GDExtensionInitialization *r_initialization) {
    GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

    init_obj.register_initializer(initialize_local_agents);
    init_obj.register_terminator(terminate_local_agents);

    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

    return init_obj.init();
}

}
