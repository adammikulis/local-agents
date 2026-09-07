#include "LAAblate.hpp"

#include "LAProcessSet.hpp"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/json.hpp>
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

const char *OFF = "off";
const char *FAKE = "fake";
const char *REAL = "real";

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

Dictionary &g_fakes() {  // stand-in name -> the ladder rung that makes `real` its default, or -1
	static Dictionary v;
	return v;
}

Dictionary &g_state() {  // stand-in name -> the state this run put it in
	static Dictionary v;
	return v;
}

bool g_parsed = false;
double g_evo = -1.0;

String &g_life() {
	static String v;
	return v;
}

// `--ablate=name[:state][@step]`, or `+name@step` to switch one back on, and LA_ABLATE. Parsed once.
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
		String state;
		const int colon = t.find(":");
		if (colon >= 0) {
			state = t.substr(colon + 1).strip_edges().to_lower();
			t = t.substr(0, colon);
			if (state != String(OFF) && state != String(FAKE) && state != String(REAL)) {
				ERR_PRINT(String("--ablate=") + t + ":" + state + ": a state is off, fake or real.");
				continue;
			}
		}
		Dictionary e;
		e["name"] = t;
		e["on"] = on;
		e["step"] = step;
		e["state"] = state;
		g_want().append(e);
	}
}

bool is_process(const String &p_name) {
	return !LAProcessSet::process_entry(p_name).is_empty();
}

// What one `--ablate=` entry asks a stand-in for: the state it names, else off for a bare name and the
// record's own default for `+name`.
String entry_state(const Dictionary &p_entry, const String &p_name) {
	const String named = p_entry["state"];
	if (named != String()) {
		return named;
	}
	return bool(p_entry["on"]) ? LAAblate::default_state(p_name) : String(OFF);
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
		if (String(e["name"]) == p_name && !bool(e["on"]) && (int)e["step"] == 0
				&& String(e["state"]) == String()) {
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

String LAAblate::state_off() {
	return String(OFF);
}

String LAAblate::state_fake() {
	return String(FAKE);
}

String LAAblate::state_real() {
	return String(REAL);
}

// Every stand-in answers to ONE name here, beside the processes and the modules.
void LAAblate::adopt_fake(const String &p_name, int p_rung) {
	if (is_process(p_name) || g_nodes().has(p_name)) {
		ERR_FAIL_MSG(String("LAAblate.adopt_fake(\"") + p_name + "\"): a process or module already "
				+ "answers to that name, so one switch would answer for two things.");
	}
	g_fakes()[p_name] = p_rung;
}

// `fake` while the rung that replaces the stand-in is outside this world, `real` once it is inside it.
String LAAblate::default_state(const String &p_name) {
	if (!g_fakes().has(p_name)) {
		return String();
	}
	const int rung = g_fakes()[p_name];
	if (rung < 0) {
		return String(FAKE);
	}
	return LAProcessSet::active() >= rung ? String(REAL) : String(FAKE);
}

int LAAblate::fake_rung(const String &p_name) {
	return g_fakes().has(p_name) ? (int)g_fakes()[p_name] : -1;
}

String LAAblate::state_of(const String &p_name) {
	if (!g_fakes().has(p_name)) {
		return String();
	}
	if (g_state().has(p_name)) {
		return g_state()[p_name];
	}
	parse();
	String out = default_state(p_name);
	const Array want = g_want();
	for (int i = 0; i < want.size(); ++i) {
		const Dictionary e = want[i];
		if (String(e["name"]) == p_name && (int)e["step"] == 0) {
			out = entry_state(e, p_name);
		}
	}
	return out;
}

void LAAblate::set_state(const String &p_name, const String &p_state) {
	if (!g_fakes().has(p_name)) {
		ERR_FAIL_MSG(String("LAAblate.set_state(\"") + p_name + "\"): no stand-in answers to that name.");
	}
	if (p_state != String(OFF) && p_state != String(FAKE) && p_state != String(REAL)) {
		ERR_FAIL_MSG(String("LAAblate.set_state(\"") + p_name + "\", \"" + p_state
				+ "\"): a state is off, fake or real.");
	}
	if (state_of(p_name) == p_state) {
		return;
	}
	g_state()[p_name] = p_state;
	Dictionary d;
	d["name"] = p_name;
	d["state"] = p_state;
	d["rung"] = LAProcessSet::name_of((int)g_fakes()[p_name]);
	UtilityFunctions::print("FAKE_STATE=" + JSON::stringify(d));
}

Dictionary LAAblate::fake_states() {
	Dictionary out;
	const Array keys = g_fakes().keys();
	for (int i = 0; i < keys.size(); ++i) {
		out[keys[i]] = state_of(String(keys[i]));
	}
	return out;
}

// Throw one switch, stand-in, module or process. A name none of the three holds is refused, out loud.
void LAAblate::set_on(const String &p_name, bool p_on) {
	if (g_fakes().has(p_name)) {
		set_state(p_name, p_on ? default_state(p_name) : String(OFF));
		return;
	}
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
	if (g_fakes().has(p_name)) {
		return state_of(p_name) != String(OFF);
	}
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
	if (g_fakes().has(p_name)) {
		return String(FAKE);
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
	PackedStringArray fakes;
	const Array fake_keys = g_fakes().keys();
	for (int i = 0; i < fake_keys.size(); ++i) {
		fakes.append(fake_keys[i]);
	}
	fakes.sort();
	out.append_array(fakes);
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
		const String name = e["name"];
		// A stand-in's step-0 entry is what state_of() already reads; a later one is thrown here.
		if (g_fakes().has(name)) {
			if (at > 0) {
				set_state(name, entry_state(e, name));
			}
			continue;
		}
		// A module's own adopt() already applied its bare name, and a bare name neither list holds is a
		// flag its own consumer reads through off().
		if (at == 0 && !is_process(name)) {
			continue;
		}
		set_on(name, (bool)e["on"]);
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
	g_fakes().clear();
	g_state().clear();
	g_parsed = false;
	g_life() = String();
	g_evo = -1.0;
}

void LAAblate::_bind_methods() {
	ClassDB::bind_static_method("LAAblate", D_METHOD("off", "name"), &off);
	ClassDB::bind_static_method("LAAblate", D_METHOD("adopt", "name", "node"), &adopt);
	ClassDB::bind_static_method("LAAblate", D_METHOD("adopt_fake", "name", "rung"), &adopt_fake);
	ClassDB::bind_static_method("LAAblate", D_METHOD("state_off"), &state_off);
	ClassDB::bind_static_method("LAAblate", D_METHOD("state_fake"), &state_fake);
	ClassDB::bind_static_method("LAAblate", D_METHOD("state_real"), &state_real);
	ClassDB::bind_static_method("LAAblate", D_METHOD("set_state", "name", "state"), &set_state);
	ClassDB::bind_static_method("LAAblate", D_METHOD("state_of", "name"), &state_of);
	ClassDB::bind_static_method("LAAblate", D_METHOD("default_state", "name"), &default_state);
	ClassDB::bind_static_method("LAAblate", D_METHOD("fake_rung", "name"), &fake_rung);
	ClassDB::bind_static_method("LAAblate", D_METHOD("fake_states"), &fake_states);
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
