#ifndef LOCAL_AGENTS_LA_FIELD_MIRRORS_HPP
#define LOCAL_AGENTS_LA_FIELD_MIRRORS_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/core/binder_common.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <unordered_map>
#include <vector>

namespace godot {

// THE CPU SIDE OF EVERY PER-CELL CHANNEL, in native storage. The drain copies the device's channels into
// one staging buffer, reads it once, and lands the bytes here; nothing cell-sized crosses into GDScript.
class LAFieldMirrors : public RefCounted {
	GDCLASS(LAFieldMirrors, RefCounted);

public:
	void set_device(RenderingDevice *p_rd);

	void alloc(const PackedStringArray &p_names, int p_cells);
	int cells() const;
	PackedStringArray names() const;
	bool has(const String &p_name) const;
	// Filled by the most recent drain. A channel nobody asked for is not live, and its values are older.
	bool live(const String &p_name) const;

	// ONE ROUND TRIP. `p_mirror_*` land in this storage; `p_probe_*` come back as arrays and touch no
	// mirror, so an instrument cannot move what the simulation reads.
	Dictionary drain(const RID &p_staging, const Array &p_mirror_srcs,
			const PackedStringArray &p_mirror_names, const Array &p_probe_srcs,
			const PackedStringArray &p_probe_names);

	// NAN where the channel or the cell is absent: a missing measurement is missing.
	double at(const String &p_name, int p_c) const;
	Vector3 vec3(const String &p_x, const String &p_y, const String &p_z, int p_c) const;
	PackedFloat32Array slice(const String &p_name, int p_from, int p_count) const;
	PackedFloat32Array array(const String &p_name) const;
	PackedByteArray bytes(const String &p_name, int p_from, int p_count) const;
	double sum(const String &p_name) const;

	void set_array(const String &p_name, const PackedFloat32Array &p_values);
	void fill(const String &p_name, double p_value);
	void set_at(const String &p_name, int p_c, double p_v);
	void add_at(const String &p_name, int p_c, double p_v);

	// For the native seed walks, which are handed the field and reach its mirrors through it.
	static LAFieldMirrors *mirrors_of(Object *p_field);
	static PackedFloat32Array of(Object *p_field, const String &p_name);
	static void store(Object *p_field, const String &p_name, const PackedFloat32Array &p_values);

protected:
	static void _bind_methods();

private:
	RenderingDevice *_rd = nullptr;
	int _cells = 0;
	PackedStringArray _names;
	std::unordered_map<std::string, int> _index;
	std::vector<float> _store;
	std::vector<uint64_t> _stamp;
	uint64_t _drain_count = 0;

	int _slot(const String &p_name) const;
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_FIELD_MIRRORS_HPP
