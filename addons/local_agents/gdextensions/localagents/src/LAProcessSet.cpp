#include "LAProcessSet.hpp"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

namespace {

const char *SETTING = "local_agents/sim/process_rung";
const char *ENV_VAR = "LA_RUNG";
const char *ARG = "--rung=";
const char *RECORDS_ARG = "--processes=";
const char *PLAYABLE_PATH = "res://docs/PLAYABLE_RUNG";
const char *AMOUNTS_TOKEN = "@amounts";

const char *TRANSPORT_GD = "res://addons/local_agents/sim/material/TransportRecords.gd";
const char *REDUCE_GD = "res://addons/local_agents/sim/material/ReduceRecords.gd";
const char *REACTIONS_GD = "res://addons/local_agents/sim/material/MaterialReactions3D.gd";
const char *BOUNDARY_GD = "res://addons/local_agents/sim/material/reduce/BoundaryRows.gd";

// --- The rungs, bottom first ------------------------------------------------------------------------
// Each names the passes, transport rows, reaction modules and reduce rows it adds to the rung below,
// and the gates that prove it. Booked channels are derived, never named twice.
const char *const NONE_[] = { nullptr };

const char *const STATE_GATES[] = { "check_rung_state.sh", "check_derive_fixed_point.sh",
	"check_condensed_moduli.sh", "check_bench_phase_change.sh",
	nullptr };
const char *const STATE_PASSES[] = { "InjectPass.gd", "StateDerivePass.gd", "ReducePass.gd", nullptr };
// The conservation books: matter and its energy are there from the bottom rung, and so is their audit.
const char *const STATE_REDUCE[] = { "@amounts", "energy_stock", "energy_stock_lith", "energy_stock_open",
	"energy_stock_open_lith", "energy_kinetic", "energy_potential", nullptr };

const char *const GRAVITY_GATES[] = { "check_gravity_solve.sh", "check_hydrosphere_mass.sh",
	"check_live_toggles.sh", nullptr };
const char *const GRAVITY_PASSES[] = { "GravityPass.gd", nullptr };
const char *const GRAVITY_REDUCE[] = { "energy_pv_solid", "energy_pv_fluid",
	"solid_cells", "carbonate_cells",
	"snow_cells", "ice_cells", "crust_latch", "crust_moved", "nonfinite_cells", "nonfinite_*",
	"derive_unconverged_cells",
	"bodyf_*", "tidal_work",
	"open_temp_*", "all_temp_max", "ground_cells", "temp_ground_sum", "hot_cells",
	"geo_grad_*", "air_grad_*", "clim_ground_*", "clim_air_*", "clim_lat*", "clim_alt*",
	"rock_*", "sea_ice_*", "open_sea_*",
	"water_liquid_total", "wet_cells", "vapour_amount", "hotspring_*", "clim_water_*",
	"melt_total", "magma_cells", "lava_*", "enclosed_void*",
	"o2_open_*", "co2_open_*", "precip_cells", "cloud_cells", "fog_cells",
	"fert_peak", "fungus_peak", "fungus_cells", "detritus_peak", "detritus_cells",
	"solid_detritus", "solid_fuel", "solid_org_h", "solid_org_o",
	"organic_hc_min", "organic_oc_min", "organic_coalified", nullptr };

const char *const HYDRO_GATES[] = { "check_hydrostatic_seed.sh", "check_atmosphere_mass.sh", "check_bench_hydrostatic_column.sh",
	nullptr };
const char *const HYDRO_PASSES[] = { "PressurePass.gd", nullptr };
const char *const HYDRO_REDUCE[] = { "pressure_*", nullptr };

// A column at rest stays at rest only where there is momentum to move it, so the rest gate is this
// rung's and not the one below's.
const char *const ACOUSTIC_GATES[] = { "check_active_rows.sh", "check_rung_acoustic.sh", "check_atmosphere_at_rest.sh",
	"check_stack_balance.sh", "check_momentum_orphans.sh", "check_boundary_momentum_book.sh", "check_bench_shock_tube.sh",
	nullptr };
const char *const ACOUSTIC_PASSES[] = { "FluxPass.gd", nullptr };
const char *const ACOUSTIC_TRANSPORT[] = { "h2o_liquid_advect", "h2o_vapour_eddy", "o2_eddy", "co2_eddy",
	"n2_eddy", "h2_eddy", "co_eddy", "so2_eddy", "h2s_eddy", "ch4_eddy", "mom_flux", nullptr };
// FluxPass's grain prologue is what splits silicate into bed, suspended and melt, so the rows that read
// those fractions are this rung's: below it nothing has written them.
const char *const ACOUSTIC_REDUCE[] = { "open_mom_*", "momentum_*", "mach_max", "rho_max_open",
	"wind_speed_max", "mineral_band_*", "mineral_loose_*", nullptr };

const char *const CONDUCTION_GATES[] = { "check_rung_conduction.sh", "check_bench_heat_slab.sh",
	nullptr };
const char *const CONDUCTION_TRANSPORT[] = { "heat_conduct", "heat_conduct_lith", nullptr };
const char *const CONDUCTION_REDUCE[] = { "radiogenic", nullptr };

const char *const ADVECT_GATES[] = { "check_rung_advect.sh", "check_boundary_books.sh", "check_bench_darcy.sh",
	nullptr };
const char *const ADVECT_TRANSPORT[] = { "h2o_surface", "h2o_groundwater", "silicate_melt_film",
	"silicate_susp_water", "silicate_susp_air", "silicate_bed",
	"fungus_wind", "fert_soil", nullptr };
const char *const ADVECT_REDUCE[] = { "airborne_mineral_sum", "suspended_cells", nullptr };

const char *const WATER_GATES[] = { "check_rung_water.sh", nullptr };
const char *const WATER_PASSES[] = { "ReactionsPass.gd", nullptr };
const char *const WATER_REACTIONS[] = { "PhaseRecords.gd", nullptr };
const char *const WATER_TRANSPORT[] = { "charge_separate", "charge_ohmic", nullptr };
const char *const WATER_REDUCE[] = { "charge_stock", "charge_gross", "charge_peak", "e_peak",
	"bolt_cells", nullptr };

const char *const RADIATION_GATES[] = { "check_radiative_row.sh", "check_alt_bands.sh", "check_bench_grey_atmosphere.sh",
	nullptr };
const char *const RADIATION_TRANSPORT[] = { "heat_radiate", nullptr };
const char *const RADIATION_REDUCE[] = { "rad_absorbed", "rad_emitted", "sw_reflected",
	"rad_sb_rel_max", nullptr };

const char *const CHEMISTRY_GATES[] = { "check_reaction_balance.sh", "check_conservation.sh",
	"check_weathering_rate_law.sh", "check_escape_law.sh", "check_gas_in_rock.sh", "check_bench_jeans_escape.sh",
	nullptr };
const char *const CHEMISTRY_REACTIONS[] = { "BioRecords.gd", "GeoRecords.gd", "CombustionRecords.gd",
	"LightningRecords.gd", nullptr };
const char *const CHEMISTRY_TRANSPORT[] = { "escape_*", nullptr };
const char *const CHEMISTRY_REDUCE[] = { "fire_peak", "fire_cells", nullptr };
const char *const CHEMISTRY_DERIVE[] = { "lithify", nullptr };

struct RungRow {
	int rung;
	const char *name;
	const char *const *gates;
	const char *const *passes;
	const char *const *transport;
	const char *const *reactions;
	const char *const *reduce;
	const char *const *derive;   // processes inside the state derive
};

const RungRow LADDER[] = {
	{ LAProcessSet::STATE, "state", STATE_GATES, STATE_PASSES, NONE_, NONE_, STATE_REDUCE, NONE_ },
	{ LAProcessSet::GRAVITY, "gravity", GRAVITY_GATES, GRAVITY_PASSES, NONE_, NONE_, GRAVITY_REDUCE, NONE_ },
	{ LAProcessSet::HYDROSTATIC, "hydrostatic", HYDRO_GATES, HYDRO_PASSES, NONE_, NONE_, HYDRO_REDUCE, NONE_ },
	{ LAProcessSet::ACOUSTIC, "acoustic", ACOUSTIC_GATES, ACOUSTIC_PASSES, ACOUSTIC_TRANSPORT, NONE_,
			ACOUSTIC_REDUCE, NONE_ },
	{ LAProcessSet::CONDUCTION, "conduction", CONDUCTION_GATES, NONE_, CONDUCTION_TRANSPORT, NONE_,
			CONDUCTION_REDUCE, NONE_ },
	{ LAProcessSet::ADVECT, "advect", ADVECT_GATES, NONE_, ADVECT_TRANSPORT, NONE_, ADVECT_REDUCE, NONE_ },
	{ LAProcessSet::WATER, "water", WATER_GATES, WATER_PASSES, WATER_TRANSPORT, WATER_REACTIONS,
			WATER_REDUCE, NONE_ },
	{ LAProcessSet::RADIATION, "radiation", RADIATION_GATES, NONE_, RADIATION_TRANSPORT, NONE_,
			RADIATION_REDUCE, NONE_ },
	{ LAProcessSet::CHEMISTRY, "chemistry", CHEMISTRY_GATES, NONE_, CHEMISTRY_TRANSPORT,
			CHEMISTRY_REACTIONS, CHEMISTRY_REDUCE, CHEMISTRY_DERIVE },
};

const int LADDER_COUNT = (int)(sizeof(LADDER) / sizeof(RungRow));

int g_active = LAProcessSet::TOP;
bool g_reduce_cached = false;
// The field step a toggle from here on takes effect at, and whether one has since the stepper last asked.
int g_step = 0;
bool g_toggled = false;

// Every process switched OFF, by name. Absent = on: a world starts with every process it contains live.
Dictionary &g_off() {
	static Dictionary v;
	return v;
}

// Constructed on first use, never at load: a Variant built by a dylib static initializer runs before
// the engine has handed the binding its interface pointers.
PackedStringArray &g_custom() {
	static PackedStringArray v;
	return v;
}

Array &g_reduce_cache() {
	static Array v;
	return v;
}

String &g_reduce_key() {
	static String v;
	return v;
}

bool g_booked_cached = false;

PackedStringArray &g_booked_cache() {
	static PackedStringArray v;
	return v;
}

String &g_booked_key() {
	static String v;
	return v;
}

// What a settled table is settled FOR: the rung asked after, and the explicit set if there is one.
String set_key(int p_rung) {
	if (p_rung == LAProcessSet::ANY) {
		return String::num_int64(p_rung) + String(":") + String(",").join(g_custom());
	}
	return String::num_int64(p_rung);
}

int clamp_rung(int p_v) {
	if (p_v < LAProcessSet::STATE) {
		return LAProcessSet::STATE;
	}
	return p_v > LAProcessSet::TOP ? (int)LAProcessSet::TOP : p_v;
}

Ref<Resource> gd_script(const char *p_path) {
	Ref<Resource> r = ResourceLoader::get_singleton()->load(String(p_path));
	ERR_FAIL_COND_V_MSG(r.is_null(), Ref<Resource>(),
			String("LAProcessSet: record module missing: ") + String(p_path));
	return r;
}

Variant gd_call(const char *p_path, const char *p_method, const Array &p_args) {
	Ref<Resource> r = gd_script(p_path);
	if (r.is_null()) {
		return Variant();
	}
	return r->callv(StringName(p_method), p_args);
}

Variant gd_const(const char *p_path, const char *p_name) {
	Ref<Resource> r = gd_script(p_path);
	if (r.is_null()) {
		return Variant();
	}
	return r->get(StringName(p_name));
}

Array transport_table() {
	return gd_call(TRANSPORT_GD, "rows", Array());
}

Array reduce_table() {
	return gd_call(REDUCE_GD, "rows", Array());
}

PackedStringArray amounts() {
	return gd_const(REDUCE_GD, "AMOUNTS");
}

PackedStringArray booked_channels() {
	const PackedStringArray signed_only = gd_const(BOUNDARY_GD, "BOOKED_SIGNED");
	PackedStringArray out = gd_const(BOUNDARY_GD, "BOOKED");
	out.append_array(signed_only);
	return out;
}

// An exact key outranks a pattern; a trailing `*` matches a prefix.
bool matches(const String &p_key, const char *const *p_want) {
	if (p_want == nullptr) {
		return false;
	}
	for (const char *const *w = p_want; *w != nullptr; ++w) {
		const String pat = String(*w);
		if (pat == String(AMOUNTS_TOKEN)) {
			const PackedStringArray names = amounts();
			for (int i = 0; i < names.size(); ++i) {
				if (p_key == "all_" + names[i] || p_key == "open_" + names[i]) {
					return true;
				}
			}
		} else if (pat.ends_with("*")) {
			if (p_key.begins_with(pat.substr(0, pat.length() - 1))) {
				return true;
			}
		} else if (pat == p_key) {
			return true;
		}
	}
	return false;
}

bool named(const String &p_key, const char *const *p_list) {
	if (p_list == nullptr) {
		return false;
	}
	for (const char *const *w = p_list; *w != nullptr; ++w) {
		if (p_key == String(*w)) {
			return true;
		}
	}
	return false;
}

Array to_array(const char *const *p_list) {
	Array out;
	if (p_list == nullptr) {
		return out;
	}
	for (const char *const *w = p_list; *w != nullptr; ++w) {
		out.append(String(*w));
	}
	return out;
}

int rung_or_active(int p_rung) {
	return p_rung == LAProcessSet::ANY ? g_active : clamp_rung(p_rung);
}

PackedStringArray cmdline() {
	PackedStringArray out = OS::get_singleton()->get_cmdline_args();
	out.append_array(OS::get_singleton()->get_cmdline_user_args());
	return out;
}

} // namespace

Array LAProcessSet::rungs() {
	Array out;
	for (int i = 0; i < LADDER_COUNT; ++i) {
		const RungRow &r = LADDER[i];
		Dictionary d;
		d["rung"] = r.rung;
		d["name"] = String(r.name);
		d["gates"] = to_array(r.gates);
		d["passes"] = to_array(r.passes);
		d["transport"] = to_array(r.transport);
		d["reactions"] = to_array(r.reactions);
		d["reduce"] = to_array(r.reduce);
		d["derive"] = to_array(r.derive);
		out.append(d);
	}
	return out;
}

// `node` is the world record's own declaration and outranks everything. Then the command line, which is
// this invocation speaking and outranks the ambient project setting and environment, and last the rung
// the ladder proved.
int LAProcessSet::resolve(int p_node) {
	if (p_node != UNSET) {
		return clamp_rung(p_node);
	}
	const PackedStringArray argv = cmdline();
	for (int i = 0; i < argv.size(); ++i) {
		if (argv[i].begins_with(ARG)) {
			return clamp_rung((int)argv[i].trim_prefix(ARG).to_int());
		}
	}
	ProjectSettings *ps = ProjectSettings::get_singleton();
	if (ps->has_setting(SETTING)) {
		const Variant v = ps->get_setting(SETTING);
		return clamp_rung((int)(int64_t)v);
	}
	const String env = OS::get_singleton()->get_environment(ENV_VAR);
	if (env != String()) {
		return clamp_rung((int)env.to_int());
	}
	return playable();
}

// An explicit process set named on the command line; empty when none is.
PackedStringArray LAProcessSet::records_from_args() {
	const PackedStringArray argv = cmdline();
	for (int i = 0; i < argv.size(); ++i) {
		if (argv[i].begins_with(RECORDS_ARG)) {
			return argv[i].trim_prefix(RECORDS_ARG).split(",", false);
		}
	}
	return PackedStringArray();
}

// The rung the demo world runs at, from docs/PLAYABLE_RUNG. The ladder raises it; nothing lowers it.
int LAProcessSet::playable() {
	Ref<FileAccess> f = FileAccess::open(String(PLAYABLE_PATH), FileAccess::READ);
	if (f.is_null()) {
		return TOP;
	}
	while (!f->eof_reached()) {
		const String line = f->get_line().strip_edges();
		if (line != String() && !line.begins_with("#")) {
			return clamp_rung((int)line.to_int());
		}
	}
	return TOP;
}

// Declared once, while the world is being seeded. Every table below answers for this world afterwards.
void LAProcessSet::declare(int p_rung) {
	g_active = clamp_rung(p_rung);
	g_custom() = PackedStringArray();
	g_off().clear();
	g_step = 0;
	g_toggled = false;
	g_reduce_cached = false;
	g_reduce_cache() = Array();
	g_booked_cached = false;
	g_booked_cache() = PackedStringArray();
}

// An explicit set: exactly these process records and nothing else, whatever rung each sits on.
void LAProcessSet::declare_records(const PackedStringArray &p_ids) {
	g_custom() = p_ids;
	g_off().clear();
	g_step = 0;
	g_toggled = false;
	g_reduce_cached = false;
	g_reduce_cache() = Array();
	g_booked_cached = false;
	g_booked_cache() = PackedStringArray();
}

void LAProcessSet::declare_world(int p_node) {
	const PackedStringArray ids = records_from_args();
	if (ids.is_empty()) {
		declare(resolve(p_node));
	} else {
		declare_records(ids);
	}
}

int LAProcessSet::active() {
	return g_active;
}

PackedStringArray LAProcessSet::custom() {
	return g_custom();
}

String LAProcessSet::name_of(int p_rung) {
	for (int i = 0; i < LADDER_COUNT; ++i) {
		if (LADDER[i].rung == p_rung) {
			return String(LADDER[i].name);
		}
	}
	return String();
}

// Every process record a world can contain, bottom rung first: one row per pass, transport row and
// reaction module. A control draws one entry per row and keeps no list of its own.
Array LAProcessSet::records() {
	const Array rows = transport_table();
	Array out;
	for (int i = 0; i < LADDER_COUNT; ++i) {
		const RungRow &r = LADDER[i];
		for (const char *const *p = r.passes; *p != nullptr; ++p) {
			Dictionary d;
			d["kind"] = String("pass");
			d["label"] = String(*p);
			d["rung"] = r.rung;
			out.append(d);
		}
		for (int j = 0; j < rows.size(); ++j) {
			const String lbl = ((Dictionary)rows[j]).get("label", String());
			if (lbl != String() && matches(lbl, r.transport)) {
				Dictionary d;
				d["kind"] = String("transport");
				d["label"] = lbl;
				d["rung"] = r.rung;
				out.append(d);
			}
		}
		for (const char *const *m = r.reactions; *m != nullptr; ++m) {
			Dictionary d;
			d["kind"] = String("reaction");
			d["label"] = String(*m);
			d["rung"] = r.rung;
			out.append(d);
		}
		for (const char *const *e = r.derive; *e != nullptr; ++e) {
			Dictionary d;
			d["kind"] = String("derive");
			d["label"] = String(*e);
			d["rung"] = r.rung;
			out.append(d);
		}
	}
	return out;
}

// The one spelling of a process on a switch, a flag and a HUD row. A pass and a reaction module are
// named after the file they live in; a transport row and a derive step already carry their own name.
String LAProcessSet::process_name(const String &p_kind, const String &p_label) {
	if (p_kind == "pass") {
		return p_label.trim_suffix(".gd").trim_suffix("Pass").to_snake_case();
	}
	if (p_kind == "reaction") {
		return p_label.trim_suffix(".gd").trim_suffix("Records").to_snake_case();
	}
	return p_label;
}

// Every process this world contains, in ladder order: what the switch list and the sweep enumerate.
PackedStringArray LAProcessSet::process_names(int p_rung) {
	const Array recs = records();
	PackedStringArray out;
	for (int i = 0; i < recs.size(); ++i) {
		const Dictionary rec = recs[i];
		if (!has_record(rec["kind"], rec["label"], p_rung)) {
			continue;
		}
		const String n = process_name(rec["kind"], rec["label"]);
		if (!out.has(n)) {
			out.append(n);
		}
	}
	return out;
}

// The record a switch name stands for, and whether it is on. Empty when this world has no such process.
Dictionary LAProcessSet::process_entry(const String &p_name) {
	const Array recs = records();
	for (int i = 0; i < recs.size(); ++i) {
		const Dictionary rec = recs[i];
		if (process_name(rec["kind"], rec["label"]) != p_name
				|| !has_record(rec["kind"], rec["label"], ANY)) {
			continue;
		}
		Dictionary d = rec.duplicate();
		d["name"] = p_name;
		d["on"] = !g_off().has(p_name);
		return d;
	}
	return Dictionary();
}

// Throw the switch. A name this world does not contain is refused: an absent process has no switch.
bool LAProcessSet::set_live(const String &p_name, bool p_on) {
	const Dictionary rec = process_entry(p_name);
	if (rec.is_empty()) {
		Dictionary d;
		d["name"] = p_name;
		d["rung"] = name_of(g_active);
		UtilityFunctions::print("PROCESS_TOGGLE_REFUSED=" + JSON::stringify(d));
		return false;
	}
	if (bool(rec["on"]) == p_on) {
		return true;
	}
	if (p_on) {
		g_off().erase(p_name);
	} else {
		g_off()[p_name] = true;
	}
	g_toggled = true;
	Dictionary d;
	d["kind"] = rec["kind"];
	d["name"] = p_name;
	d["on"] = p_on;
	d["step"] = g_step;
	UtilityFunctions::print("PROCESS_TOGGLE=" + JSON::stringify(d));
	return true;
}

bool LAProcessSet::is_active(const String &p_kind, const String &p_label, int p_rung) {
	return has_record(p_kind, p_label, p_rung) && !g_off().has(process_name(p_kind, p_label));
}

bool LAProcessSet::is_switched_on(const String &p_kind, const String &p_label) {
	return !g_off().has(process_name(p_kind, p_label));
}

Dictionary LAProcessSet::live_mask() {
	const PackedStringArray names = process_names(ANY);
	Dictionary out;
	for (int i = 0; i < names.size(); ++i) {
		out[names[i]] = !g_off().has(names[i]);
	}
	return out;
}

void LAProcessSet::note_step(int p_step) {
	g_step = p_step;
}

bool LAProcessSet::take_toggled() {
	const bool was = g_toggled;
	g_toggled = false;
	return was;
}

// The one spelling of a record in a serialised set.
String LAProcessSet::record_id(const Dictionary &p_rec) {
	return String(p_rec["kind"]) + String(":") + String(p_rec["label"]);
}

// The record ids of every process at or below `rung` -- what a rung selection serialises to.
PackedStringArray LAProcessSet::records_upto(int p_rung) {
	const Array recs = records();
	PackedStringArray out;
	for (int i = 0; i < recs.size(); ++i) {
		const Dictionary rec = recs[i];
		if ((int)rec["rung"] <= p_rung) {
			out.append(record_id(rec));
		}
	}
	return out;
}

// Is this process in the world? An explicit set answers by name, a rung by height.
bool LAProcessSet::has_record(const String &p_kind, const String &p_label, int p_rung) {
	if (p_label == String()) {
		return false;
	}
	if (p_rung == ANY && !g_custom().is_empty()) {
		return g_custom().has(p_kind + String(":") + p_label);
	}
	const int at = rung_or_active(p_rung);
	for (int i = 0; i < LADDER_COUNT; ++i) {
		const RungRow &r = LADDER[i];
		if (r.rung > at) {
			continue;
		}
		if (p_kind == "transport") {
			if (matches(p_label, r.transport)) {
				return true;
			}
		} else if (p_kind == "pass") {
			if (named(p_label, r.passes)) {
				return true;
			}
		} else if (p_kind == "reaction") {
			if (named(p_label, r.reactions)) {
				return true;
			}
		} else if (p_kind == "derive") {
			if (named(p_label, r.derive)) {
				return true;
			}
		}
	}
	return false;
}

// Every rung holding at least one process this world contains.
Array LAProcessSet::live_rungs() {
	const Array recs = records();
	Array out;
	for (int i = 0; i < recs.size(); ++i) {
		const Dictionary rec = recs[i];
		const int at = rec["rung"];
		if (!out.has(at) && has_record(rec["kind"], rec["label"], ANY)) {
			out.append(at);
		}
	}
	return out;
}

// Absolute paths of the pass scripts this world runs, in the driver's dispatch order.
PackedStringArray LAProcessSet::pass_paths(const PackedStringArray &p_all_paths, int p_rung) {
	PackedStringArray out;
	for (int i = 0; i < p_all_paths.size(); ++i) {
		if (has_record("pass", p_all_paths[i].get_file(), p_rung)) {
			out.append(p_all_paths[i]);
		}
	}
	return out;
}

// The transport rows this world moves. A row outside the set is never bound and never dispatched.
Array LAProcessSet::transport_rows(int p_rung) {
	const Array rows = transport_table();
	Array out;
	for (int i = 0; i < rows.size(); ++i) {
		const Dictionary row = rows[i];
		if (has_record("transport", row.get("label", String()), p_rung)) {
			out.append(row);
		}
	}
	return out;
}

// The reduce rows this world folds. A row whose rung holds no live process is the instrument of
// nothing here, so it is never dispatched and its reading is absent rather than zero.
Array LAProcessSet::reduce_rows(int p_rung) {
	// The ledger folds these on every field step; the set is settled at seeding, so the walk runs once.
	const String key = set_key(p_rung);
	if (g_reduce_cached && key == g_reduce_key()) {
		return g_reduce_cache();
	}
	const Array live = (p_rung == ANY && !g_custom().is_empty()) ? live_rungs() : Array();
	const int at = rung_or_active(p_rung);
	const PackedStringArray book = booked(p_rung);
	const Array rows = reduce_table();
	Array out;
	for (int i = 0; i < rows.size(); ++i) {
		const Dictionary row = rows[i];
		const int owner = reduce_rung(row["key"], book);
		if (owner == UNSET) {
			continue;
		}
		if (!live.is_empty()) {
			if (!live.has(owner)) {
				continue;
			}
		} else if (owner > at) {
			continue;
		}
		out.append(row);
	}
	g_reduce_key() = key;
	g_reduce_cache() = out;
	g_reduce_cached = true;
	return out;
}

// The rung that declared a reduce row; UNSET when none did. A boundary book follows its own channel.
int LAProcessSet::reduce_rung(const String &p_key, const PackedStringArray &p_book) {
	for (int i = 0; i < LADDER_COUNT; ++i) {
		if (matches(p_key, LADDER[i].reduce)) {
			return LADDER[i].rung;
		}
	}
	if (p_book.is_empty()) {
		return UNSET;
	}
	const String amount_prefix = gd_const(BOUNDARY_GD, "BOOKED_PREFIX");
	const String heat_prefix = gd_const(BOUNDARY_GD, "HEAT_PREFIX");
	for (int i = 0; i < p_book.size(); ++i) {
		if (p_key == amount_prefix + p_book[i] || p_key == heat_prefix + p_book[i]) {
			return channel_rung(p_book[i]);
		}
	}
	return UNSET;
}

// The lowest rung carrying a transport row for `channel`; UNSET when nothing moves it.
int LAProcessSet::channel_rung(const String &p_channel) {
	const Array rows = transport_table();
	for (int i = 0; i < LADDER_COUNT; ++i) {
		for (int j = 0; j < rows.size(); ++j) {
			const Dictionary row = rows[j];
			if (row_books(row).has(p_channel)
					&& matches(row.get("label", String()), LADDER[i].transport)) {
				return LADDER[i].rung;
			}
		}
	}
	return UNSET;
}

// The channels one record's crossings land in: its own, or the explicit legs it declares.
PackedStringArray LAProcessSet::row_books(const Dictionary &p_row) {
	PackedStringArray out;
	if (p_row.has("books")) {
		const Array legs = p_row["books"];
		for (int i = 0; i < legs.size(); ++i) {
			out.append(legs[i]);
		}
		return out;
	}
	out.append(p_row.get("channel", String()));
	return out;
}

// Channels whose boundary crossings this world books: those a live transport row can carry across.
PackedStringArray LAProcessSet::booked(int p_rung) {
	const String key = set_key(p_rung);
	if (g_booked_cached && key == g_booked_key()) {
		return g_booked_cache();
	}
	const PackedStringArray all = booked_channels();
	const Array rows = transport_rows(p_rung);
	PackedStringArray out;
	for (int i = 0; i < rows.size(); ++i) {
		const PackedStringArray legs = row_books(rows[i]);
		for (int j = 0; j < legs.size(); ++j) {
			const String ch = legs[j];
			if (!out.has(ch) && all.has(ch)) {
				out.append(ch);
			}
		}
	}
	g_booked_key() = key;
	g_booked_cache() = out;
	g_booked_cached = true;
	return out;
}

bool LAProcessSet::books(const String &p_channel) {
	return booked(ANY).has(p_channel);
}

// The reaction records this world runs, balance-checked as one table.
Array LAProcessSet::reaction_records(int p_rung) {
	const PackedStringArray modules = gd_const(REACTIONS_GD, "RECORD_MODULES");
	PackedStringArray paths;
	for (int i = 0; i < modules.size(); ++i) {
		if (has_record("reaction", modules[i].get_file(), p_rung)) {
			paths.append(modules[i]);
		}
	}
	Array args;
	args.append(paths);
	return gd_call(REACTIONS_GD, "records_from", args);
}

String LAProcessSet::amounts_token() {
	return String(AMOUNTS_TOKEN);
}

void LAProcessSet::release() {
	g_reduce_cache() = Array();
	g_reduce_cached = false;
	g_reduce_key() = String();
	g_booked_cache() = PackedStringArray();
	g_booked_cached = false;
	g_booked_key() = String();
	g_custom() = PackedStringArray();
	g_off().clear();
}

void LAProcessSet::_bind_methods() {
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("rungs"), &rungs);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("resolve", "node"), &resolve);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("records_from_args"), &records_from_args);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("playable"), &playable);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("declare", "rung"), &declare);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("declare_records", "ids"), &declare_records);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("declare_world", "node"), &declare_world);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("active"), &active);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("custom"), &custom);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("name_of", "rung"), &name_of);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("records"), &records);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("record_id", "rec"), &record_id);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("records_upto", "rung"), &records_upto);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("has_record", "kind", "label", "rung"),
			&has_record, DEFVAL(ANY));
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("live_rungs"), &live_rungs);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("process_name", "kind", "label"), &process_name);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("process_names", "rung"), &process_names,
			DEFVAL(ANY));
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("process_entry", "name"), &process_entry);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("set_live", "name", "on"), &set_live);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("is_active", "kind", "label", "rung"),
			&is_active, DEFVAL(ANY));
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("is_switched_on", "kind", "label"),
			&is_switched_on);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("live_mask"), &live_mask);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("note_step", "step"), &note_step);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("take_toggled"), &take_toggled);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("pass_paths", "all_paths", "rung"),
			&pass_paths, DEFVAL(ANY));
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("transport_rows", "rung"), &transport_rows,
			DEFVAL(ANY));
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("reduce_rows", "rung"), &reduce_rows,
			DEFVAL(ANY));
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("reduce_rung", "key", "book"), &reduce_rung,
			DEFVAL(PackedStringArray()));
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("channel_rung", "channel"), &channel_rung);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("booked", "rung"), &booked, DEFVAL(ANY));
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("books", "channel"), &books);
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("reaction_records", "rung"), &reaction_records,
			DEFVAL(ANY));
	ClassDB::bind_static_method("LAProcessSet", D_METHOD("amounts_token"), &amounts_token);

	BIND_ENUM_CONSTANT(STATE);
	BIND_ENUM_CONSTANT(GRAVITY);
	BIND_ENUM_CONSTANT(HYDROSTATIC);
	BIND_ENUM_CONSTANT(ACOUSTIC);
	BIND_ENUM_CONSTANT(CONDUCTION);
	BIND_ENUM_CONSTANT(ADVECT);
	BIND_ENUM_CONSTANT(WATER);
	BIND_ENUM_CONSTANT(RADIATION);
	BIND_ENUM_CONSTANT(CHEMISTRY);
	BIND_CONSTANT(TOP);
	BIND_CONSTANT(UNSET);
	BIND_CONSTANT(ANY);
}
