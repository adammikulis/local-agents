#include "LAFieldLedger.hpp"

#include "LAPlanetTables.hpp"
#include "LAProcessSet.hpp"
#include "LASubstances.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/core/object.hpp>

#include <cmath>

using namespace godot;

namespace {

const char *ENERGY_STORES[] = { "energy_stock", "energy_stock_lith", "energy_stock_open",
	"energy_stock_open_lith", "energy_kinetic", "energy_potential" };

inline double as_d(const Variant &p_v) {
	return static_cast<double>(p_v);
}

} // namespace

void LAFieldLedger::configure(const Dictionary &p_tables) {
	_amounts = p_tables.get("amounts", PackedStringArray());
	_groups = p_tables.get("groups", Dictionary());
	_lith = p_tables.get("lith_channels", PackedStringArray());
	_composition = p_tables.get("composition", Dictionary());
	_substance = p_tables.get("substance", Dictionary());
	_bnd_amount = p_tables.get("bnd_amount", String());
	_bnd_heat = p_tables.get("bnd_heat", String());
	_bnd_signed = p_tables.get("bnd_signed", PackedStringArray());
	_dt_s = as_d(p_tables.get("dt_s", 0.0));
	_configured = true;
}

void LAFieldLedger::set_seal(Object *p_seal) {
	_seal_id = p_seal != nullptr ? p_seal->get_instance_id() : 0;
}

bool LAFieldLedger::_sealed() const {
	if (_seal_id == 0) {
		return false;
	}
	Object *s = ObjectDB::get_instance(_seal_id);
	return s != nullptr && static_cast<bool>(s->call("sealed"));
}

void LAFieldLedger::_note_seed(const String &p_key, double p_value) const {
	if (_seal_id == 0) {
		return;
	}
	Object *s = ObjectDB::get_instance(_seal_id);
	if (s == nullptr) {
		return;
	}
	Dictionary d;
	d[p_key] = p_value;
	s->call("note_seed", d);
}

PackedStringArray LAFieldLedger::_group(const char *p_name) const {
	return _groups.get(String(p_name), PackedStringArray());
}

double LAFieldLedger::_sum_of(const Dictionary &p_by_channel, const PackedStringArray &p_group) {
	double acc = 0.0;
	for (int i = 0; i < p_group.size(); i++) {
		acc += as_d(p_by_channel.get(p_group[i], 0.0));
	}
	return acc;
}

Dictionary LAFieldLedger::_only(const Dictionary &p_m, const PackedStringArray &p_group) {
	Dictionary out;
	for (int i = 0; i < p_group.size(); i++) {
		out[p_group[i]] = as_d(p_m.get(p_group[i], 0.0));
	}
	return out;
}

Dictionary LAFieldLedger::_elements_of(const Dictionary &p_by_channel) const {
	Dictionary out;
	const Array channels = p_by_channel.keys();
	for (int i = 0; i < channels.size(); i++) {
		const Variant ch = channels[i];
		const Dictionary parts = _composition.get(ch, Dictionary());
		const double moles = as_d(p_by_channel[ch]);
		const Array els = parts.keys();
		for (int j = 0; j < els.size(); j++) {
			const Variant el = els[j];
			out[el] = as_d(out.get(el, 0.0)) + moles * as_d(parts[el]);
		}
	}
	return out;
}

Dictionary LAFieldLedger::_lith_elements(const Dictionary &p_by_channel) const {
	return _elements_of(_only(p_by_channel, _lith));
}

Variant LAFieldLedger::_rel(double p_numerator, double p_denominator) {
	if (!std::isfinite(p_numerator) || !std::isfinite(p_denominator)) {
		return Variant();
	}
	if (p_denominator == 0.0) {
		return p_numerator != 0.0 ? 1.0 : 0.0;
	}
	return Math::snapped(p_numerator / std::abs(p_denominator), 1.0e-12);
}

bool LAFieldLedger::_absent(const PackedStringArray &p_group) const {
	const Dictionary live = _latest.get("live", Dictionary());
	for (int i = 0; i < p_group.size(); i++) {
		if (!static_cast<bool>(live.get(p_group[i], false))) {
			return true;
		}
	}
	return false;
}

Dictionary LAFieldLedger::_live_of(const PackedStringArray &p_group) const {
	const Dictionary live = _latest.get("live", Dictionary());
	Dictionary out;
	for (int i = 0; i < p_group.size(); i++) {
		out[p_group[i]] = static_cast<bool>(live.get(p_group[i], false));
	}
	return out;
}

// --- the drain, reshaped ------------------------------------------------------------------------------

void LAFieldLedger::fold(const Dictionary &p_drained, double p_mineral_minted,
		double p_inject_heat_j) {
	if (!_configured || p_drained.is_empty()) {
		return;
	}
	Dictionary out;
	Dictionary live;
	Dictionary amt_all;
	Dictionary amt_open;
	for (int i = 0; i < _amounts.size(); i++) {
		const String name = _amounts[i];
		const bool present = p_drained.has("all_" + name) && p_drained.has("open_" + name);
		live[name] = present;
		if (!present) {
			continue;
		}
		amt_all[name] = as_d(p_drained["all_" + name]);
		amt_open[name] = as_d(p_drained["open_" + name]);
	}
	out["live"] = live;
	out["all"] = amt_all;
	out["open"] = amt_open;
	out["step"] = static_cast<int>(as_d(p_drained.get("reduce_step", -1.0)));
	if (p_drained.has("carbonate_cells")) {
		out["carbonate_cells"] = static_cast<int>(as_d(p_drained["carbonate_cells"]));
	}
	if (p_drained.has("snow_cells") && p_drained.has("ice_cells")) {
		out["snow_cells"] = static_cast<int>(as_d(p_drained["snow_cells"]));
		out["ice_cells"] = static_cast<int>(as_d(p_drained["ice_cells"]));
	}
	// Half, because a cell that gained rock is matched by one that lost it.
	if (p_drained.has("crust_moved")
			&& static_cast<int>(as_d(p_drained.get("crust_ref_step", -1.0))) >= 0) {
		out["crust_moved"] = as_d(p_drained["crust_moved"]) * 0.5;
		out["crust_ref_step"] = static_cast<int>(as_d(p_drained["crust_ref_step"]));
	}
	if (p_drained.has("charge_stock") && p_drained.has("charge_gross")) {
		out["charge_stock"] = as_d(p_drained["charge_stock"]);
		out["charge_gross"] = as_d(p_drained["charge_gross"]);
	}
	// The stores the world's energy is the sum of; one the device did not deliver is named, never skipped.
	PackedStringArray want;
	for (const char *key : ENERGY_STORES) {
		want.push_back(String(key));
	}
	const Array rows = LAProcessSet::reduce_rows(LAProcessSet::ANY);
	for (int i = 0; i < rows.size(); i++) {
		const Dictionary row = rows[i];
		if (static_cast<bool>(row.get("energy_book", false))) {
			want.push_back(String(row["key"]));
		}
	}
	PackedStringArray absent;
	for (int i = 0; i < want.size(); i++) {
		const String key = want[i];
		if (p_drained.has(key)) {
			out[key] = as_d(p_drained[key]);
		} else {
			absent.push_back(key);
		}
	}
	out["energy_missing"] = absent;
	const Array drained_keys = p_drained.keys();
	for (int i = 0; i < drained_keys.size(); i++) {
		const String key = drained_keys[i];
		if (key.begins_with(_bnd_amount)) {
			out[key] = as_d(p_drained[key]);
		}
	}
	out["bnd_declared"] = boundary_declared(_bnd_signed);

	_latest = out;
	if (!_sealed()) {
		return;
	}
	// The baselines latch on the fold the crossing integral opens on, so drift and crossings span the
	// same steps; this fold's own crossings are already inside the stock it latched.
	if (!_latched) {
		_latched = true;
		report(static_cast<int>(out["step"]), p_mineral_minted, p_inject_heat_j);
		return;
	}
	boundary_sample(out);
}

// --- the boundary books -------------------------------------------------------------------------------

PackedStringArray LAFieldLedger::boundary_declared(const PackedStringArray &p_signed) {
	PackedStringArray out;
	const PackedStringArray booked = LAProcessSet::booked(LAProcessSet::ANY);
	for (int i = 0; i < booked.size(); i++) {
		if (!p_signed.has(booked[i])) {
			out.push_back(booked[i]);
		}
	}
	return out;
}

void LAFieldLedger::boundary_sample(const Dictionary &p_drained) {
	_bnd_missing = PackedStringArray();
	const PackedStringArray declared = boundary_declared(_bnd_signed);
	for (int i = 0; i < declared.size(); i++) {
		const String ch = declared[i];
		const String a = _bnd_amount + ch;
		const String h = _bnd_heat + ch;
		if (!p_drained.has(a)) {
			_bnd_missing.push_back(a);
		}
		if (!p_drained.has(h)) {
			_bnd_missing.push_back(h);
		}
		if (!p_drained.has(a) || !p_drained.has(h)) {
			continue;
		}
		const double d = as_d(p_drained[a]);
		const double dh = as_d(p_drained[h]);
		_bnd_net[ch] = as_d(_bnd_net.get(ch, 0.0)) + d;
		_bnd_gross[ch] = as_d(_bnd_gross.get(ch, 0.0)) + std::abs(d);
		_bnd_heat_net += dh;
		_bnd_heat_gross += std::abs(dh);
	}
	const PackedStringArray booked = LAProcessSet::booked(LAProcessSet::ANY);
	for (int i = 0; i < booked.size(); i++) {
		const String sch = booked[i];
		if (!_bnd_signed.has(sch)) {
			continue;
		}
		const String sa = _bnd_amount + sch;
		if (!p_drained.has(sa)) {
			_bnd_missing.push_back(sa);
			continue;
		}
		const double sd = as_d(p_drained[sa]);
		_bnd_net[sch] = as_d(_bnd_net.get(sch, 0.0)) + sd;
		_bnd_gross[sch] = as_d(_bnd_gross.get(sch, 0.0)) + std::abs(sd);
	}
}

PackedStringArray LAFieldLedger::boundary_missing() const {
	return _bnd_missing;
}

double LAFieldLedger::boundary_heat_net() const {
	return _bnd_heat_net;
}

double LAFieldLedger::boundary_heat_gross() const {
	return _bnd_heat_gross;
}

Array LAFieldLedger::boundary_of(const PackedStringArray &p_group, const String &p_element) const {
	bool starved = false;
	for (int i = 0; i < p_group.size(); i++) {
		if (_bnd_missing.has(_bnd_amount + p_group[i])) {
			starved = true;
		}
	}
	Array out;
	if (p_element.is_empty()) {
		out.push_back(_sum_of(_bnd_net, p_group));
		out.push_back(_sum_of(_bnd_gross, p_group));
		out.push_back(starved);
		return out;
	}
	const Dictionary e_in = _elements_of(_only(_bnd_net, p_group));
	const Dictionary e_gr = _elements_of(_only(_bnd_gross, p_group));
	out.push_back(as_d(e_in.get(p_element, 0.0)));
	out.push_back(as_d(e_gr.get(p_element, 0.0)));
	out.push_back(starved);
	return out;
}

// --- the baselines ------------------------------------------------------------------------------------

int LAFieldLedger::_elapsed(const String &p_key, int p_step) {
	int out = 0;
	if (_prev_s.has(p_key)) {
		out = p_step - static_cast<int>(_prev_s[p_key]);
		if (out < 0) {
			out = 0;
		}
	}
	if (!_prev_s.has(p_key) || p_step > static_cast<int>(_prev_s[p_key])) {
		_prev_s[p_key] = p_step;
	}
	return out;
}

Array LAFieldLedger::_run(const String &p_key, const String &p_seed_key, double p_value, int p_step) {
	Array out;
	if (!_first_s.has(p_key)) {
		if (!_sealed()) {
			return out;
		}
		_first_v[p_key] = p_value;
		_first_s[p_key] = p_step;
		if (!p_seed_key.is_empty()) {
			_note_seed(p_seed_key, p_value);
		}
	}
	const double f = as_d(_first_v[p_key]);
	const int first_step = static_cast<int>(_first_s[p_key]);
	const int steps = p_step - first_step;
	out.push_back(f);
	out.push_back(p_value - f);
	out.push_back(steps > 0 ? (p_value - f) / static_cast<double>(steps) : 0.0);
	out.push_back(steps);
	out.push_back(first_step);
	return out;
}

int LAFieldLedger::_first_step_of(const String &p_key) const {
	return _first_s.has(p_key) ? static_cast<int>(_first_s[p_key]) : -1;
}

int LAFieldLedger::_run_pair(Dictionary &p_out, const String &p_name, const String &p_book,
		const String &p_seed_key, double p_value, int p_step, const Array &p_bnd, double p_scale) {
	const Array r = _run(p_book, p_seed_key, p_value, p_step);
	if (r.is_empty()) {
		return 0;
	}
	p_out[p_name + String("_first")] = Math::snapped(as_d(r[0]), 0.01);
	p_out[p_name + String("_run_drift")] = Math::snapped(as_d(r[1]), 0.01);
	p_out[p_name + String("_bnd_in")] = as_d(p_bnd[0]);
	p_out[p_name + String("_bnd_crossed")] = as_d(p_bnd[1]);
	const double denom = p_scale >= 0.0 ? p_scale : std::abs(as_d(r[0])) + as_d(p_bnd[1]);
	p_out[p_name + String("_rel_drift")] = static_cast<bool>(p_bnd[2])
			? Variant()
			: _rel(as_d(r[1]) - as_d(p_bnd[0]), denom);
	return static_cast<int>(r[3]);
}

// --- the published block ------------------------------------------------------------------------------

Dictionary LAFieldLedger::report(int p_step, double p_mineral_minted, double p_inject_heat_j) {
	Dictionary out;
	if (!_configured || _latest.is_empty()) {
		return out;
	}
	// The step the reduction ran at, which is not the step the report is being written at.
	int step = static_cast<int>(_latest["step"]);
	if (step < 0) {
		step = p_step;
	}
	out["bnd_declared"] = _latest.get("bnd_declared", PackedStringArray());
	_publish_h2o(out, step);
	_publish_mineral(out, step, p_mineral_minted);
	_publish_element(out, step);
	_publish_energy(out, step, p_inject_heat_j);
	_publish_charge(out, step);
	_last = out;
	return out;
}

double LAFieldLedger::total(const String &p_key) const {
	const Variant v = _last.get(p_key, Variant());
	const Variant::Type t = v.get_type();
	return (t == Variant::FLOAT || t == Variant::INT) ? as_d(v) : 0.0;
}

void LAFieldLedger::_publish_h2o(Dictionary &p_out, int p_step) {
	const PackedStringArray group = _group("h2o");
	if (_absent(group)) {
		p_out["h2o_total"] = Variant();
		return;
	}
	const Dictionary all = _latest["all"];
	const double h2o = _sum_of(all, group);
	p_out["h2o_total"] = Math::snapped(h2o, 0.01);
	if (_latest.has("snow_cells")) {
		p_out["snow_cells"] = _latest["snow_cells"];
		p_out["ice_cells"] = _latest["ice_cells"];
	}
	_run_pair(p_out, "h2o", "h2o", "h2o", h2o, p_step, boundary_of(group, String()));
}

void LAFieldLedger::_publish_mineral(Dictionary &p_out, int p_step, double p_mineral_minted) {
	const PackedStringArray group = _group("mineral");
	p_out["mineral_live"] = _live_of(group);
	if (_absent(group)) {
		p_out["mineral_total"] = Variant();
		return;
	}
	const Dictionary all = _latest["all"];
	const Dictionary lith = _lith_elements(all);
	const double total = as_d(lith.get("Si", 0.0));
	p_out["mineral_total"] = Math::snapped(total, 0.01);
	p_out["carbonate_cells"] = _latest.get("carbonate_cells", 0);
	if (_latest.has("crust_moved")) {
		p_out["crust_moved"] = Math::snapped(as_d(_latest["crust_moved"]), 0.01);
	}
	const Array els = lith.keys();
	for (int i = 0; i < els.size(); i++) {
		p_out["lith_element_" + String(els[i])] = Math::snapped(as_d(lith[els[i]]), 0.01);
	}
	// erupt_source injects mantle lava with no debit in the field, so the queue books it.
	p_out["mineral_src_total"] = Math::snapped(p_mineral_minted, 0.01);
	_run_pair(p_out, "mineral", "mineral", "mineral", total, p_step, boundary_of(group, "Si"));
	// Every element the rock alone holds gets its own drift book, keyed on its lith moles.
	if (!_lith_only_built) {
		_build_lith_only();
	}
	for (int i = 0; i < _lith_only.size(); i++) {
		const String el = _lith_only[i];
		_run_pair(p_out, "lith_" + el, "lith_" + el, String(), as_d(lith.get(el, 0.0)), p_step,
				boundary_of(group, el));
	}
	_publish_daughters(p_out);
}

// An element some channel outside the rock also carries moves between pools, and a book over the rock
// alone would read that transfer as drift; `mineral` already books Si.
void LAFieldLedger::_build_lith_only() {
	_lith_only_built = true;
	Dictionary elsewhere;
	const Array channels = _composition.keys();
	for (int i = 0; i < channels.size(); i++) {
		if (_lith.has(channels[i])) {
			continue;
		}
		const Dictionary parts = _composition[channels[i]];
		const Array els = parts.keys();
		for (int j = 0; j < els.size(); j++) {
			elsewhere[els[j]] = true;
		}
	}
	for (int i = 0; i < _lith.size(); i++) {
		const Dictionary parts = _composition.get(_lith[i], Dictionary());
		const Array els = parts.keys();
		for (int j = 0; j < els.size(); j++) {
			const String el = els[j];
			if (el == "Si" || elsewhere.has(el) || _lith_only.has(el)) {
				continue;
			}
			_lith_only.push_back(el);
		}
	}
}

void LAFieldLedger::_build_daughters() {
	_daughters_built = true;
	const double epoch = LARadiogenicDecay::epoch_years();
	const Dictionary table = LASubstances::table();
	const PackedStringArray group = _group("mineral");
	for (int i = 0; i < group.size(); i++) {
		const String ch = group[i];
		const Dictionary s = table.get(String(_substance.get(ch, String())), Dictionary());
		const double molar_mass = as_d(s.get("molar_mass", 0.0));
		const Dictionary d = LARadiogenicDecay::daughters_mol_per_kg(s.get("traces", Dictionary()),
				epoch);
		Dictionary per_mole;
		const Array els = d.keys();
		for (int j = 0; j < els.size(); j++) {
			per_mole[els[j]] = molar_mass * as_d(d[els[j]]);
		}
		_daughters[ch] = per_mole;
	}
}

// Radiogenic daughters accumulated in the rock since the planet formed, moles: the parents' traces decay
// in closed form, so the He and Ar the rock holds are computed, never seeded.
void LAFieldLedger::_publish_daughters(Dictionary &p_out) {
	if (!_daughters_built) {
		_build_daughters();
	}
	const Dictionary all = _latest["all"];
	const PackedStringArray group = _group("mineral");
	Dictionary acc;
	for (int i = 0; i < group.size(); i++) {
		const String ch = group[i];
		if (!all.has(ch)) {
			continue;
		}
		const double amount = as_d(all[ch]);
		const Dictionary per_mole = _daughters.get(ch, Dictionary());
		const Array els = per_mole.keys();
		for (int j = 0; j < els.size(); j++) {
			const Variant el = els[j];
			acc[el] = as_d(acc.get(el, 0.0)) + amount * as_d(per_mole[el]);
		}
	}
	const Array els = acc.keys();
	for (int i = 0; i < els.size(); i++) {
		p_out["radiogenic_" + String(els[i]) + "_mol"] = Math::snapped(as_d(acc[els[i]]), 1e-6);
	}
}

void LAFieldLedger::_publish_element(Dictionary &p_out, int p_step) {
	const PackedStringArray group = _group("element");
	p_out["mass_live"] = _live_of(group);
	if (_absent(group)) {
		p_out["carbon_total"] = Variant();
		p_out["o2_total"] = Variant();
		p_out["oxidant_total"] = Variant();
		p_out["oxidant_all"] = Variant();
		p_out["nitrogen_all"] = Variant();
		return;
	}
	const Dictionary all = _latest["all"];
	const Dictionary open = _latest["open"];
	const PackedStringArray carbon_g = _group("carbon");
	const PackedStringArray oxidant_g = _group("oxidant");
	const PackedStringArray closed_g = _group("carbon_closed");
	const double carbon = _sum_of(open, carbon_g);
	const double oxidant_all = _sum_of(all, oxidant_g);
	const double closed_all = _sum_of(all, closed_g);
	p_out["carbon_total"] = Math::snapped(carbon, 0.01);
	p_out["o2_total"] = Math::snapped(as_d(open["o2"]), 0.01);
	p_out["oxidant_total"] = Math::snapped(_sum_of(open, oxidant_g), 0.01);
	p_out["oxidant_all"] = Math::snapped(oxidant_all, 0.01);

	const Dictionary elements = _elements_of(_only(open, group));
	const Array el_keys = elements.keys();
	for (int i = 0; i < el_keys.size(); i++) {
		p_out["element_" + String(el_keys[i])] = Math::snapped(as_d(elements[el_keys[i]]), 0.01);
	}
	// A channel amount IS moles, so nothing is converted: element_N_all is the nitrogen over every pool.
	const Dictionary elements_all = _elements_of(_only(all, group));
	const Array all_keys = elements_all.keys();
	for (int i = 0; i < all_keys.size(); i++) {
		p_out["element_" + String(all_keys[i]) + "_all"] =
				Math::snapped(as_d(elements_all[all_keys[i]]), 0.01);
	}
	const double nitrogen_all = as_d(elements_all.get("N", 0.0));
	p_out["nitrogen_all"] = Math::snapped(nitrogen_all, 0.01);

	// The gated totals are latched MASK-FREE: a substance moving into rock is buried, not destroyed.
	// `carbon_rel_drift` stays on the open triangle, to localise a leak to one side of the reaction table.
	_run_pair(p_out, "carbon", "carbon", "carbon", carbon, p_step, boundary_of(carbon_g, String()));
	PackedStringArray o2_only;
	o2_only.push_back("o2");
	PackedStringArray fert_only;
	fert_only.push_back("fert");
	PackedStringArray biomass_only;
	biomass_only.push_back("biomass");
	_run_pair(p_out, "o2", "o2", "o2", as_d(open["o2"]), p_step, boundary_of(o2_only, String()));
	_run_pair(p_out, "fert", "fert", String(), as_d(open["fert"]), p_step,
			boundary_of(fert_only, String()));
	_run_pair(p_out, "biomass", "biomass", String(), as_d(open["biomass"]), p_step,
			boundary_of(biomass_only, String()));
	_run_pair(p_out, "oxidant", "oxidant", String(), oxidant_all, p_step,
			boundary_of(oxidant_g, String()));
	_run_pair(p_out, "carbon_closed", "carbon_closed", String(), closed_all, p_step,
			boundary_of(closed_g, String()));
	_run_pair(p_out, "nitrogen", "nitrogen", String(), nitrogen_all, p_step,
			boundary_of(group, "N"));
	// Elemental H over every pool water included: what Jeans escape drains, closed by its bnd legs.
	PackedStringArray h_pool = group;
	h_pool.append_array(_group("h2o"));
	_run_pair(p_out, "hydrogen", "hydrogen", String(),
			as_d(_elements_of(_only(all, h_pool)).get("H", 0.0)), p_step, boundary_of(h_pool, "H"));
}

void LAFieldLedger::_publish_energy(Dictionary &p_out, int p_step, double p_inject_heat_j) {
	const PackedStringArray missing = _latest.get("energy_missing", PackedStringArray());
	if (missing.size() > 0 || !_latest.has("energy_stock") || !_latest.has("energy_stock_lith")) {
		p_out["energy_stock"] = Variant();
		return;
	}
	// THE FIRST LAW'S TOTAL: both reservoirs' internal energy plus motion plus potential.
	const double stock = as_d(_latest["energy_stock"]) + as_d(_latest["energy_stock_lith"]);
	p_out["energy_stock"] = stock;
	p_out["energy_stock_open"] = _latest.has("energy_stock_open_lith")
			? Variant(as_d(_latest["energy_stock_open"]) + as_d(_latest["energy_stock_open_lith"]))
			: Variant();
	const double held = stock + as_d(_latest["energy_kinetic"]) + as_d(_latest["energy_potential"]);
	p_out["energy_held"] = held;

	// WATTS, off the device. flux.glsl's RADIATE row writes what each cell took in and sent out as
	// J/m^3 for one step; the two reduce rows weight those by cell volume, so the pair arrives in joules
	// over one step and only the step's own real seconds separate it from watts.
	const bool has_rad = _latest.has("rad_absorbed") && _latest.has("rad_emitted")
			&& _latest.has("radiogenic") && _dt_s > 0.0;
	// A world that declares no radiative record exchanges nothing by radiation; one that declares it
	// and publishes no reading is unmeasured.
	const bool rad_declared = LAProcessSet::has_record("transport", "heat_radiate", LAProcessSet::ANY);
	const double absorbed_w = has_rad ? as_d(_latest.get("rad_absorbed", 0.0)) / _dt_s : 0.0;
	const double emitted_w = has_rad ? as_d(_latest.get("rad_emitted", 0.0)) / _dt_s : 0.0;
	const double radiogenic_w = has_rad ? as_d(_latest.get("radiogenic", 0.0)) / _dt_s : 0.0;
	p_out["energy_net_w"] = has_rad ? Variant(absorbed_w - emitted_w) : Variant();

	// THE STOCK AND ITS DRIFT STAND WITHOUT THE RADIATIVE PAIR. A world whose processes do not include
	// radiation exchanges no energy with anything, so what it holds must not move; only the RESIDUAL —
	// the drift net of what was booked — needs terms to book against.
	const int steps = _elapsed("energy_held", p_step);
	const bool was_latched = _first_step_of("energy_held") >= 0;
	const Array r = _run("energy_held", "energy_j", held, p_step);
	if (r.is_empty()) {
		return;
	}
	p_out["energy_held_first"] = as_d(r[0]);
	p_out["energy_run_drift"] = as_d(r[1]);
	p_out["energy_run_drift_rel"] = _rel(as_d(r[1]), std::abs(as_d(r[0])));
	if (rad_declared && !has_rad) {
		// A missing measurement is missing: the declared radiative pair published no reading.
		p_out["energy_booked"] = Variant();
		p_out["energy_residual"] = Variant();
		p_out["energy_residual_rel"] = Variant();
		p_out["energy_turnover_j"] = Variant();
		return;
	}
	if (!was_latched) {
		_cum_absorbed = 0.0;
		_cum_emitted = 0.0;
		_cum_radiogenic = 0.0;
		_first_inject_j = p_inject_heat_j;
	} else if (steps > 0) {
		// Rectangle rule over the window, at the flux sampled at its right-hand end, integrated against
		// the real seconds the kernel applies.
		const double window_s = _dt_s * static_cast<double>(steps);
		_cum_absorbed += absorbed_w * window_s;
		_cum_emitted += emitted_w * window_s;
		_cum_radiogenic += radiogenic_w * window_s;
	}
	if (static_cast<int>(r[3]) <= 0) {
		return;
	}
	const double run_drift = as_d(r[1]);
	const double cum_inject = p_inject_heat_j - _first_inject_j;
	// The joules that crossed the open edge with the matter. POSITIVE IS INTO the domain, so they are
	// booked with the same sign as absorbed sunlight; zero while the wall is shut.
	const double booked = _cum_absorbed - _cum_emitted + cum_inject + _cum_radiogenic + _bnd_heat_net;
	// What entered or left the thermal field over the window, and the only admissible denominator for the
	// residual: read as a fraction of the STOCK, a wholly unaccounted window reports as round-off.
	const double turnover = _cum_absorbed + _cum_emitted + std::abs(cum_inject)
			+ std::abs(_cum_radiogenic) + _bnd_heat_gross;
	p_out["energy_booked"] = booked;
	p_out["energy_residual"] = run_drift - booked;
	p_out["energy_turnover_j"] = turnover;
	p_out["energy_bnd_in"] = _bnd_heat_net;
	p_out["energy_bnd_crossed"] = _bnd_heat_gross;
	p_out["energy_residual_rel"] = _bnd_missing.is_empty()
			? _rel(run_drift - booked, turnover)
			: Variant();
}

// Net charge over the box, coulombs: no heat leg, so the edge crossing books amount-only. Riming
// separates it in ZERO-SUM pairs, so the net is a residual whose scale is the charge that EXISTS.
void LAFieldLedger::_publish_charge(Dictionary &p_out, int p_step) {
	if (!_latest.has("charge_stock")) {
		p_out["charge_stock"] = Variant();
		p_out["charge_gross"] = Variant();
		return;
	}
	const double gross = as_d(_latest["charge_gross"]);
	const double stock = as_d(_latest["charge_stock"]);
	p_out["charge_stock"] = stock;
	p_out["charge_gross"] = gross;
	PackedStringArray charge_only;
	charge_only.push_back("charge");
	_run_pair(p_out, "charge", "charge", "charge_c", stock, p_step,
			boundary_of(charge_only, String()), gross);
}

// --- momentum -----------------------------------------------------------------------------------------

void LAFieldLedger::momentum_sample(int p_step, const Vector3 &p_stock, const Vector3 &p_body,
		const Vector3 &p_bnd) {
	const int steps = p_step - _mom_prev_step;
	if (steps > 0 || _mom_prev_step < 0) {
		_mom_prev_step = p_step;
	}
	if (_mom_first_step < 0) {
		if (_sealed() && p_stock.is_finite()) {
			_mom_first_stock = p_stock;
			_mom_first_step = p_step;
			_note_seed("momentum_kg_m_s", p_stock.length());
		}
		return;
	}
	// Both books are impulses PER STEP; a non-finite step's book is absent, never folded.
	if (steps > 0 && p_body.is_finite() && p_bnd.is_finite()) {
		_cum_body += p_body * static_cast<double>(steps);
		_cum_bnd += p_bnd * static_cast<double>(steps);
		_cum_impulse += (p_body.length() + p_bnd.length()) * static_cast<double>(steps);
	}
}

Dictionary LAFieldLedger::momentum_report(int p_step, const Vector3 &p_stock, const Vector3 &p_body,
		const Vector3 &p_bnd, double p_carried, double p_mass_kg, int p_cells) {
	Dictionary out;
	Dictionary live;
	live["stock"] = p_stock.is_finite();
	live["bodyf"] = p_body.is_finite();
	live["bnd_mom"] = p_bnd.is_finite();
	out["momentum_live"] = live;
	const int run_steps = _mom_first_step >= 0 ? p_step - _mom_first_step : 0;
	out["momentum_first_step"] = _mom_first_step;
	out["momentum_run_steps"] = run_steps;
	if (run_steps > 0) {
		// The books are sums of finite per-step folds, so they stand even when the instant stock does not.
		out["momentum_book_body"] = _vec(_cum_body);
		out["momentum_book_bnd"] = _vec(_cum_bnd);
		out["momentum_impulse"] = _cum_impulse;
	}
	if (!p_stock.is_finite()) {
		return out;
	}
	out["momentum_vec"] = _vec(p_stock);
	out["momentum_total"] = static_cast<double>(p_stock.length());
	out["momentum_carried"] = p_carried;
	out["momentum_mass_kg"] = p_mass_kg;
	out["momentum_cells"] = p_cells;
	if (run_steps <= 0) {
		return out;
	}
	const Vector3 run_drift = p_stock - _mom_first_stock;
	const Vector3 residual = run_drift - (_cum_body + _cum_bnd);
	out["momentum_run_drift_vec"] = _vec(run_drift);
	out["momentum_run_drift"] = static_cast<double>(run_drift.length());
	// Sum m|v| is the motion that exists; a net stock change is a fraction OF it.
	out["momentum_run_drift_rel"] = p_carried == 0.0
			? Variant()
			: _rel(run_drift.length(), p_carried);
	out["momentum_residual_vec"] = _vec(residual);
	out["momentum_residual"] = static_cast<double>(residual.length());
	out["momentum_residual_rel"] = _cum_impulse == 0.0
			? Variant()
			: _rel(residual.length(), _cum_impulse);
	return out;
}

Array LAFieldLedger::_vec(const Vector3 &p_v) {
	Array out;
	out.push_back(static_cast<double>(p_v.x));
	out.push_back(static_cast<double>(p_v.y));
	out.push_back(static_cast<double>(p_v.z));
	return out;
}

void LAFieldLedger::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "tables"), &LAFieldLedger::configure);
	ClassDB::bind_method(D_METHOD("set_seal", "seal"), &LAFieldLedger::set_seal);
	ClassDB::bind_method(D_METHOD("fold", "drained", "mineral_minted", "inject_heat_j"),
			&LAFieldLedger::fold);
	ClassDB::bind_method(D_METHOD("report", "step", "mineral_minted", "inject_heat_j"),
			&LAFieldLedger::report);
	ClassDB::bind_method(D_METHOD("total", "key"), &LAFieldLedger::total);
	ClassDB::bind_static_method("LAFieldLedger", D_METHOD("boundary_declared", "signed_channels"),
			&LAFieldLedger::boundary_declared);
	ClassDB::bind_method(D_METHOD("boundary_sample", "drained"), &LAFieldLedger::boundary_sample);
	ClassDB::bind_method(D_METHOD("boundary_missing"), &LAFieldLedger::boundary_missing);
	ClassDB::bind_method(D_METHOD("boundary_heat_net"), &LAFieldLedger::boundary_heat_net);
	ClassDB::bind_method(D_METHOD("boundary_heat_gross"), &LAFieldLedger::boundary_heat_gross);
	ClassDB::bind_method(D_METHOD("boundary_of", "group", "element"), &LAFieldLedger::boundary_of,
			DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("momentum_sample", "step", "stock", "body", "bnd"),
			&LAFieldLedger::momentum_sample);
	ClassDB::bind_method(
			D_METHOD("momentum_report", "step", "stock", "body", "bnd", "carried", "mass_kg", "cells"),
			&LAFieldLedger::momentum_report);
}
