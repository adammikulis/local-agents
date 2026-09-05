#include <godot_cpp/godot.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include "AgentNode.hpp"
#include "AgentRuntime.hpp"
#include "LAAbsorptionBands.hpp"
#include "LABallistics.hpp"
#include "LAMixtureEnthalpy.hpp"
#include "LABodySystem.hpp"
#include "LAFieldCellMass.hpp"
#include "LAGridGeometry.hpp"
#include "LAGravityMultigrid.hpp"
#include "LAGravityPotential.hpp"
#include "LAFieldDriver.hpp"
#include "LAFieldLedger.hpp"
#include "LAFieldMirrors.hpp"
#include "LAFieldSnapshot.hpp"
#include "LAFieldStateCache.hpp"
#include "LAFieldHydrosphereSeed.hpp"
#include "LAFieldLithostaticSeed.hpp"
#include "LAPlanetTables.hpp"
#include "LASubstances.hpp"
#include "NetworkGraph.hpp"
#include "LAProcess.hpp"
#include "LAProcessSet.hpp"
#include "LANoActivation.hpp"

using namespace godot;

namespace {
AgentRuntime *g_agent_runtime_singleton = nullptr;

void initialize_local_agents(ModuleInitializationLevel p_level) {
    // CORE runs before the DisplayServer exists, which is the only point where this can be decided: the
    // engine has no command-line override for a project setting, and _ready is long after macOS has made
    // the window key and dragged the user out of whatever Space they were in.
    if (p_level == MODULE_INITIALIZATION_LEVEL_CORE) {
        // NEVER under the editor or the importer: both SAVE project.godot, which would persist this into
        // the tree and ship the game with a window that cannot take focus.
        bool saves_settings = false;
        const PackedStringArray argv = OS::get_singleton()->get_cmdline_args();
        for (int i = 0; i < argv.size(); ++i) {
            const String a = argv[i];
            if (a == "--editor" || a == "-e" || a == "--import" || a == "--export-release"
                    || a == "--export-debug" || a == "--export-pack") {
                saves_settings = true;
                break;
            }
        }
        la_prohibit_activation();
        if (!saves_settings && OS::get_singleton()->get_environment("LA_OFFSCREEN") != String()) {
            ProjectSettings *ps = ProjectSettings::get_singleton();
            // Initial value too: a save writes only what differs from it, so this cannot reach the tree
            // even if something saves anyway. The cmdline guard above is the belt; this is the braces.
            ps->set_setting("display/window/size/no_focus", true);
            ps->set_initial_value("display/window/size/no_focus", true);
        }
        return;
    }
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }

    ClassDB::register_class<AgentRuntime>();
    ClassDB::register_class<AgentNode>();
    ClassDB::register_class<NetworkGraph>();
    ClassDB::register_class<LAProcess>();
    ClassDB::register_class<LAProcessSet>();
    ClassDB::register_class<LAAbsorptionBands>();
    ClassDB::register_class<LAElementAbundances>();
    ClassDB::register_class<LAPlanetComposition>();
    ClassDB::register_class<LARadiogenicDecay>();
    ClassDB::register_class<LAOrbitState>();
    ClassDB::register_class<LABodySeeds>();
    ClassDB::register_class<LAFieldCellMass3D>();
    ClassDB::register_class<LAGridGeometry>();
    ClassDB::register_class<LAGravityMultigrid>();
    ClassDB::register_class<LAGravityPotential>();
    ClassDB::register_class<LABallistics>();
    ClassDB::register_class<LAFieldDriver>();
    ClassDB::register_class<LAFieldLedger>();
    ClassDB::register_class<LAFieldMirrors>();
    ClassDB::register_class<LAFieldSnapshot>();
    ClassDB::register_class<LAFieldStateCache>();
    ClassDB::register_class<LABodyMeasure>();
    ClassDB::register_class<LAFieldHydrosphereSeed>();
    ClassDB::register_class<LAFieldLithostaticSeed>();
    ClassDB::register_class<LASubstances>();
    ClassDB::register_class<LAMixtureEnthalpy>();

    if (!g_agent_runtime_singleton) {
        g_agent_runtime_singleton = memnew(AgentRuntime);
        g_agent_runtime_singleton->set_name("AgentRuntime");
        Engine::get_singleton()->register_singleton(StringName("AgentRuntime"), g_agent_runtime_singleton);
    }
}

void terminate_local_agents(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }

    LAProcessSet::release();

    if (g_agent_runtime_singleton) {
        Engine::get_singleton()->unregister_singleton(StringName("AgentRuntime"));
        memdelete(g_agent_runtime_singleton);
        g_agent_runtime_singleton = nullptr;
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

    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_CORE);

    return init_obj.init();
}

}
