#include "LAFieldFill.hpp"

#include "LAFieldMirrors.hpp"
#include "LAPhaseEos.hpp"
#include "LAPhysicalRead.hpp"
#include "LAScriptCall.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>
#include <limits>
#include <vector>

using namespace godot;

namespace {

const char *CHANNELS_GD = "res://addons/local_agents/sim/material/Channels.gd";

struct Share {
	String channel;
	String substance;
	double x = 0.0;
};

// The declared mixture as the gas channels carry it. Empty, with the reason pushed, where a key is not a gas
// channel, a fraction is negative, or the fractions do not sum to one within their own rounding.
std::vector<Share> shares_of(const Dictionary &p_mole_fractions) {
	const Dictionary rows = la_call_gd(CHANNELS_GD, "rows", Array());
	const Array keys = p_mole_fractions.keys();
	std::vector<Share> out;
	double sum = 0.0;
	for (int i = 0; i < keys.size(); i++) {
		const String ch = keys[i];
		const Dictionary row = rows.get(ch, Dictionary());
		const double x = double(p_mole_fractions[keys[i]]);
		if (String(row.get("phase", "")) != "gas" || String(row.get("unit", "")) != "mol_m3") {
			UtilityFunctions::push_error("LAFieldFill: \"" + ch + "\" is not a gas channel.");
			return {};
		}
		if (!(x >= 0.0)) {
			UtilityFunctions::push_error("LAFieldFill: \"" + ch + "\" has a mole fraction below zero.");
			return {};
		}
		sum += x;
		out.push_back({ ch, String(row.get("substance", "")), x });
	}
	const double ulp = std::numeric_limits<double>::epsilon() * double(MAX(int(keys.size()), 1));
	if (out.empty() || std::abs(sum - 1.0) > ulp) {
		UtilityFunctions::push_error("LAFieldFill: the mole fractions sum to " + String::num(sum, 17) + ", not one.");
		return {};
	}
	return out;
}

} // namespace

bool LAFieldFill::valid_spec(const Variant &p_fill) {
	if (p_fill.get_type() != Variant::DICTIONARY) { return false; }
	const Dictionary fill = p_fill;
	if (fill.is_empty()) { return true; }
	const Variant fractions = fill.get("mole_fractions", Variant());
	const Variant pressure = fill.get("pressure_pa", Variant());
	return fractions.get_type() == Variant::DICTIONARY
			&& (pressure.get_type() == Variant::FLOAT || pressure.get_type() == Variant::INT);
}

String LAFieldFill::cache_key(const String &p_base, const Dictionary &p_fill, double p_temp_c) {
	if (p_base.is_empty()) { return p_base; }
	Dictionary declaration;
	declaration["fill"] = p_fill;
	declaration["temp_c"] = p_temp_c;
	return (p_base + JSON::stringify(declaration, String(), true, true)).sha256_text();
}

double LAFieldFill::gas_molar_density(const Dictionary &p_mole_fractions, double p_temp_c, double p_pressure_pa) {
	const std::vector<Share> shares = shares_of(p_mole_fractions);
	const double t_k = p_temp_c + la_physical("KELVIN_OFFSET");
	if (shares.empty() || !(t_k > 0.0) || !std::isfinite(t_k)
			|| !(p_pressure_pa > 0.0) || !std::isfinite(p_pressure_pa)) {
		UtilityFunctions::push_error("LAFieldFill: no mixture, or a temperature or pressure at or below zero.");
		return NAN;
	}
	// The one-fluid sums per mole, as la_eos_p takes them: sum x_i sqrt(a_i(T)) and sum x_i b_i.
	double sa = 0.0;
	double sb = 0.0;
	for (const Share &s : shares) {
		const LAFluidEos &fl = LAPhaseEosFn::fluid(s.substance);
		if (!fl.valid) {
			UtilityFunctions::push_error("LAFieldFill: gas \"" + s.substance + "\" has no fluid equation of state.");
			return NAN;
		}
		sa += s.x * std::sqrt(LAPhaseEosFn::pr_a(fl, t_k));
		sb += s.x * fl.b;
	}
	const double rt = la_physical("GAS_CONSTANT_J_MOL_K") * t_k;
	const double p_std = la_physical("STANDARD_PRESSURE_PA");
	auto p_of = [&](double n) {
		return LAPhaseEosFn::mixture_pressure(1.0, n * rt, n * sa, n * sb, 0.0, 0.0, p_std);
	};
	// The ideal amount, then toward the co-volume n b = 1 until the cubic reaches the pressure.
	const double n_cap = sb > 0.0 ? 1.0 / sb : std::numeric_limits<double>::infinity();
	double lo = 0.0;
	double hi = MIN(p_pressure_pa / rt, 0.5 * n_cap);
	for (int i = 0; i < 64 && !(p_of(hi) >= p_pressure_pa); i++) {
		lo = hi;
		hi = std::isfinite(n_cap) ? 0.5 * (hi + n_cap) : 2.0 * hi;
	}
	if (!(p_of(hi) >= p_pressure_pa)) {
		UtilityFunctions::push_error("LAFieldFill: the mixture's equation of state reaches no "
				+ String::num(p_pressure_pa) + " Pa below its co-volume at " + String::num(p_temp_c) + " C.");
		return NAN;
	}
	for (int i = 0; i < 128 && hi - lo > std::numeric_limits<double>::epsilon() * hi; i++) {
		const double mid = 0.5 * (lo + hi);
		if (p_of(mid) < p_pressure_pa) {
			lo = mid;
		} else {
			hi = mid;
		}
	}
	return 0.5 * (lo + hi);
}

bool LAFieldFill::lay_gas(Object *p_field, const Dictionary &p_mole_fractions, double p_temp_c,
		double p_pressure_pa) {
	ERR_FAIL_NULL_V(p_field, false);
	LAFieldMirrors *m = LAFieldMirrors::mirrors_of(p_field);
	const int cc = int(p_field->get("_cell_count"));
	const PackedByteArray solid = p_field->get("_solid");
	const PackedFloat32Array rock = p_field->get("_rock_fraction");
	if (m == nullptr || cc <= 0 || m->cells() != cc || solid.size() != cc) {
		UtilityFunctions::push_error("LAFieldFill: the field has no cells or no mirrors to lay a mixture in.");
		return false;
	}
	for (int c = 0; c < cc; c++) {
		if (solid[c] != 0 || (rock.size() == cc && rock[c] > 0.0f)) {
			UtilityFunctions::push_error("LAFieldFill: the field holds rock, so one gas mixture is not all of its matter.");
			return false;
		}
	}
	const double n = gas_molar_density(p_mole_fractions, p_temp_c, p_pressure_pa);
	if (!(n > 0.0) || !std::isfinite(n)) {
		return false;
	}
	for (const Share &s : shares_of(p_mole_fractions)) {
		if (!m->has(s.channel)) {
			UtilityFunctions::push_error("LAFieldFill: the field allocated no \"" + s.channel + "\" mirror.");
			return false;
		}
		m->fill(s.channel, s.x * n);
	}
	// This declaration contains gas only: no terrain or free-liquid volume exists at the seed boundary.
	PackedFloat32Array absent;
	absent.resize(cc);
	absent.fill(0.0f);
	p_field->set("_rock_fraction", absent);
	p_field->set("_water_fraction", absent);
	absent.fill(NAN);
	p_field->set("_surface_depth", absent);
	// No lattice stands in the field; the temperature one would stand at is the mixture's.
	PackedFloat32Array t;
	t.resize(cc);
	t.fill(float(p_temp_c));
	p_field->set("_t_rock", t);
	return true;
}

void LAFieldFill::_bind_methods() {
	ClassDB::bind_static_method("LAFieldFill", D_METHOD("valid_spec", "fill"), &LAFieldFill::valid_spec);
	ClassDB::bind_static_method("LAFieldFill", D_METHOD("cache_key", "base", "fill", "temp_c"), &LAFieldFill::cache_key);
	ClassDB::bind_static_method("LAFieldFill",
			D_METHOD("gas_molar_density", "mole_fractions", "temp_c", "pressure_pa"), &LAFieldFill::gas_molar_density);
	ClassDB::bind_static_method("LAFieldFill", D_METHOD("lay_gas", "field", "mole_fractions", "temp_c", "pressure_pa"),
			&LAFieldFill::lay_gas);
}
