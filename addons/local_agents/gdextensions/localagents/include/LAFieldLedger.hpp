#ifndef LOCAL_AGENTS_LA_FIELD_LEDGER_HPP
#define LOCAL_AGENTS_LA_FIELD_LEDGER_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/binder_common.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

// THE CONSERVATION BOOKS, kept in double. One drained reduction folded per field step, the per-channel
// edge crossings integrated on that same clock, the baselines latched when the seal says they may, and
// one published block per conserved substance. A store the device did not deliver publishes null.
class LAFieldLedger : public RefCounted {
	GDCLASS(LAFieldLedger, RefCounted);

public:
	// The channel groups, compositions and prefixes, each off its one GDScript declaration.
	void configure(const Dictionary &p_tables);
	// LAMaterialFieldSeal3D. It decides when a baseline may latch and receives every seed note.
	void set_seal(Object *p_seal);

	// One drain, reshaped into per-channel books, then latched or integrated.
	void fold(const Dictionary &p_drained, double p_mineral_minted, double p_inject_heat_j);
	Dictionary report(int p_step, double p_mineral_minted, double p_inject_heat_j);
	double total(const String &p_key) const;

	// `bnd_<channel>` is units crossing the domain edge per step, `bnd_h_<channel>` the joules with them.
	static PackedStringArray boundary_declared(const PackedStringArray &p_signed);
	void boundary_sample(const Dictionary &p_drained);
	PackedStringArray boundary_missing() const;
	double boundary_heat_net() const;
	double boundary_heat_gross() const;
	Array boundary_of(const PackedStringArray &p_group, const String &p_element) const;

	// Momentum stock in the field frame; both books are impulses per step.
	void momentum_sample(int p_step, const Vector3 &p_stock, const Vector3 &p_body, const Vector3 &p_bnd);
	Dictionary momentum_report(int p_step, const Vector3 &p_stock, const Vector3 &p_body,
			const Vector3 &p_bnd, double p_carried, double p_mass_kg, int p_cells);

protected:
	static void _bind_methods();

private:
	PackedStringArray _amounts;
	Dictionary _groups;      // group name -> PackedStringArray of channels
	PackedStringArray _lith; // lithosphere channels
	Dictionary _composition; // channel -> {element: count per unit}
	Dictionary _substance;   // channel -> substance id in LASubstances::table()
	String _bnd_amount;
	String _bnd_heat;
	PackedStringArray _bnd_signed;
	double _dt_s = 0.0;
	bool _configured = false;

	uint64_t _seal_id = 0;

	Dictionary _latest; // the last drain folded
	Dictionary _last;   // the last block published

	Dictionary _first_v;
	Dictionary _first_s;
	Dictionary _prev_s;
	bool _latched = false;

	PackedStringArray _bnd_missing;
	Dictionary _bnd_net;
	Dictionary _bnd_gross;
	double _bnd_heat_net = 0.0;
	double _bnd_heat_gross = 0.0;

	double _cum_absorbed = 0.0;
	double _cum_emitted = 0.0;
	double _cum_radiogenic = 0.0;
	double _first_inject_j = 0.0;

	int _mom_prev_step = -1;
	int _mom_first_step = -1;
	Vector3 _mom_first_stock;
	Vector3 _cum_body;
	Vector3 _cum_bnd;
	double _cum_impulse = 0.0;

	// Moles of each radiogenic daughter per mole of channel, closed-form over the epoch. Built once.
	Dictionary _daughters;
	bool _daughters_built = false;

	bool _sealed() const;
	void _note_seed(const String &p_key, double p_value) const;

	PackedStringArray _group(const char *p_name) const;
	static double _sum_of(const Dictionary &p_by_channel, const PackedStringArray &p_group);
	static Dictionary _only(const Dictionary &p_m, const PackedStringArray &p_group);
	Dictionary _elements_of(const Dictionary &p_by_channel) const;
	Dictionary _lith_elements(const Dictionary &p_by_channel) const;
	static Variant _rel(double p_numerator, double p_denominator);
	static Array _vec(const Vector3 &p_v);
	bool _absent(const PackedStringArray &p_group) const;
	Dictionary _live_of(const PackedStringArray &p_group) const;

	int _elapsed(const String &p_key, int p_step);
	Array _run(const String &p_key, const String &p_seed_key, double p_value, int p_step);
	int _first_step_of(const String &p_key) const;
	int _run_pair(Dictionary &p_out, const String &p_name, const String &p_book,
			const String &p_seed_key, double p_value, int p_step, const Array &p_bnd,
			double p_scale = -1.0);

	void _publish_h2o(Dictionary &p_out, int p_step);
	void _publish_mineral(Dictionary &p_out, int p_step, double p_mineral_minted);
	void _publish_daughters(Dictionary &p_out);
	void _publish_element(Dictionary &p_out, int p_step);
	void _publish_energy(Dictionary &p_out, int p_step, double p_inject_heat_j);
	void _publish_charge(Dictionary &p_out, int p_step);
	void _build_daughters();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_FIELD_LEDGER_HPP
