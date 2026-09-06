#include "LAAblate.hpp"

#include "LAProcessSet.hpp"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>

using namespace godot;

namespace {

const char *FLAG = "--ablate=";
const char *ENV_ABLATE = "LA_ABLATE";
const char *ENV_LIFE = "LA_LIFE_MODE";
const char *ENV_EVO = "LA_EVO_FAST";
const char *META_LIFE = "la_life_mode";

const char *LIFE_FULL = "full";
const char *LIFE_NO_FAUNA = "no_fauna";
const char *LIFE_PLANET_ONLY = "planet_only";

// Constructed on first use, never at load: a Variant built by a dylib static initializer runs before
// the engine has handed the binding its interface pointers.
Dictionary &g_nodes() {  // module name -> the node that IS that system
	static Dictionary v;
	return v;
}

Array &g_want() {  // `--ablate=` entries: {name, on, step}
	static Array v;
	return v;
}

Dictionary &g_applied() {  // entry index -> thrown
	static Dictionary v;
	return v;
}

bool g_parsed = false;
double g_evo = -1.0;

String &g_life() {
	static String v;
	return v;
}

// `--ablate=name[@step]`, or `+name@step` to switch one back on, and LA_ABLATE. Parsed once.
void parse() {
	if (g_parsed) {
		return;
	}
	g_parsed = true;
	String csv = OS::get_singleton()->get_environment(ENV_ABLATE);
	const PackedStringArray argv = OS::get_singleton()->get_cmdline_user_args();
	for (int i = 0; i < argv.size(); ++i) {
		if (argv[i].begins_with(FLAG)) {
			csv += String(",") + argv[i].trim_prefix(FLAG);
		}
	}
	const PackedStringArray tokens = csv.split(",", false);
	for (int i = 0; i < tokens.size(); ++i) {
		String t = tokens[i].strip_edges();
		if (t == String()) {
			continue;
		}
		const bool on = t.begins_with("+");
		if (on) {
			t = t.substr(1);
		}
		int step = 0;
		const int at = t.find("@");
		if (at >= 0) {
			step = std::max((int)t.substr(at + 1).to_int(), 0);
			t = t.substr(0, at);
		}
		Dictionary e;
		e["name"] = t;
		e["on"] = on;
		e["step"] = step;
		g_want().append(e);
	}
}

bool is_process(const String &p_name) {
	return !LAProcessSet::process_entry(p_name).is_empty();
}

Node *node_of(const String &p_name) {
	if (!g_nodes().has(p_name)) {
		return nullptr;
	}
	Object *obj = Object::cast_to<Object>(g_nodes()[p_name]);
	if (obj == nullptr || !UtilityFunctions::is_instance_id_valid(obj->get_instance_id())) {
		return nullptr;
	}
	return Object::cast_to<Node>(obj);
}

} // namespace

// Named off from the start of the run.
bool LAAblate::off(const String &p_name) {
	parse();
	const Array want = g_want();
	for (int i = 0; i < want.size(); ++i) {
		const Dictionary e = want[i];
		if (String(e["name"]) == p_name && !bool(e["on"]) && (int)e["step"] == 0) {
			return true;
		}
	}
	return false;
}

// Every per-frame module answers to ONE name here. Off = no processing, no timers, not drawn.
void LAAblate::adopt(const String &p_name, Node *p_node) {
	if (p_node == nullptr) {
		return;
	}
	if (is_process(p_name)) {
		ERR_FAIL_MSG(String("LAAblate.adopt(\"") + p_name + "\"): the rung already contains a process of "
				+ "that name, so one switch would answer for two things.");
	}
	g_nodes()[p_name] = p_node;
	if (off(p_name)) {
		set_on(p_name, false);
		UtilityFunctions::print(String("ABLATED={name:") + p_name + "}");
	}
}

// Throw one switch, module or process. A name that is neither is refused by LAProcessSet, out loud.
void LAAblate::set_on(const String &p_name, bool p_on) {
	if (g_nodes().has(p_name)) {
		Node *node = node_of(p_name);
		if (node == nullptr) {
			return;
		}
		node->set_process_mode(p_on ? Node::PROCESS_MODE_INHERIT : Node::PROCESS_MODE_DISABLED);
		if (node->has_method("set_visible") && !node->is_class("Camera3D")) {
			node->set("visible", p_on);
		}
		return;
	}
	LAProcessSet::set_live(p_name, p_on);
}

bool LAAblate::is_on(const String &p_name) {
	if (g_nodes().has(p_name)) {
		Node *node = node_of(p_name);
		return node != nullptr && node->get_process_mode() != Node::PROCESS_MODE_DISABLED;
	}
	return (bool)LAProcessSet::live_mask().get(p_name, true);
}

String LAAblate::kind_of(const String &p_name) {
	if (g_nodes().has(p_name)) {
		return String("module");
	}
	return is_process(p_name) ? String("process") : String();
}

PackedStringArray LAAblate::names() {
	PackedStringArray out = LAProcessSet::process_names(LAProcessSet::ANY);
	PackedStringArray mods;
	const Array keys = g_nodes().keys();
	for (int i = 0; i < keys.size(); ++i) {
		mods.append(keys[i]);
	}
	mods.sort();
	out.append_array(mods);
	return out;
}

void LAAblate::apply_schedule(int p_step) {
	parse();
	const Array want = g_want();
	for (int i = 0; i < want.size(); ++i) {
		const Dictionary e = want[i];
		const int at = e["step"];
		if (g_applied().has(i) || at > p_step) {
			continue;
		}
		g_applied()[i] = true;
		// A module's own adopt() already applied its bare name, and a bare name neither list holds is a
		// flag its own consumer reads through off().
		if (at == 0 && !is_process(String(e["name"]))) {
			continue;
		}
		set_on(String(e["name"]), (bool)e["on"]);
	}
}

bool LAAblate::step_switches(int p_step) {
	LAProcessSet::note_step(p_step);
	apply_schedule(p_step);
	return LAProcessSet::take_toggled();
}

String LAAblate::life_full() {
	return String(LIFE_FULL);
}

String LAAblate::life_no_fauna() {
	return String(LIFE_NO_FAUNA);
}

String LAAblate::life_planet_only() {
	return String(LIFE_PLANET_ONLY);
}

// Resolved life mode for this run.
String LAAblate::life_mode() {
	if (g_life() != String()) {
		return g_life();
	}
	g_life() = String(LIFE_FULL);
	Engine *engine = Engine::get_singleton();
	if (engine->has_meta(META_LIFE)) {
		g_life() = String(engine->get_meta(META_LIFE));
	} else {
		const String env = OS::get_singleton()->get_environment(ENV_LIFE);
		if (env != String()) {
			g_life() = env.strip_edges().to_lower();
		}
	}
	if (g_life() != String(LIFE_NO_FAUNA) && g_life() != String(LIFE_PLANET_ONLY)) {
		g_life() = String(LIFE_FULL);
	}
	return g_life();
}

// True when ANIMALS (creatures, fish, insects) must not be spawned or simulated at all.
bool LAAblate::fauna_off() {
	return life_mode() != String(LIFE_FULL);
}

// True when VEGETATION must not be spawned either -- pure geophysics. This changes the planet's
// CHEMISTRY, so a climate reading here is not comparable with one from a vegetated run.
bool LAAblate::flora_off() {
	return life_mode() == String(LIFE_PLANET_ONLY);
}

double LAAblate::evo_fast() {
	if (g_evo < 0.0) {
		g_evo = 1.0;
		const String env = OS::get_singleton()->get_environment(ENV_EVO);
		if (env != String()) {
			g_evo = std::min(std::max(env.to_float(), 1.0), 50.0);
		}
	}
	return g_evo;
}

void LAAblate::release() {
	g_nodes().clear();
	g_want().clear();
	g_applied().clear();
	g_parsed = false;
	g_life() = String();
	g_evo = -1.0;
}

void LAAblate::_bind_methods() {
	ClassDB::bind_static_method("LAAblate", D_METHOD("off", "name"), &off);
	ClassDB::bind_static_method("LAAblate", D_METHOD("adopt", "name", "node"), &adopt);
	ClassDB::bind_static_method("LAAblate", D_METHOD("set_on", "name", "on"), &set_on);
	ClassDB::bind_static_method("LAAblate", D_METHOD("is_on", "name"), &is_on);
	ClassDB::bind_static_method("LAAblate", D_METHOD("kind_of", "name"), &kind_of);
	ClassDB::bind_static_method("LAAblate", D_METHOD("names"), &names);
	ClassDB::bind_static_method("LAAblate", D_METHOD("apply_schedule", "step"), &apply_schedule);
	ClassDB::bind_static_method("LAAblate", D_METHOD("step_switches", "step"), &step_switches);
	ClassDB::bind_static_method("LAAblate", D_METHOD("life_full"), &life_full);
	ClassDB::bind_static_method("LAAblate", D_METHOD("life_no_fauna"), &life_no_fauna);
	ClassDB::bind_static_method("LAAblate", D_METHOD("life_planet_only"), &life_planet_only);
	ClassDB::bind_static_method("LAAblate", D_METHOD("life_mode"), &life_mode);
	ClassDB::bind_static_method("LAAblate", D_METHOD("fauna_off"), &fauna_off);
	ClassDB::bind_static_method("LAAblate", D_METHOD("flora_off"), &flora_off);
	ClassDB::bind_static_method("LAAblate", D_METHOD("evo_fast"), &evo_fast);
}
