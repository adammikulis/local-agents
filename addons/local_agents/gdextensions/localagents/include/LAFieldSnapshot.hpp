#ifndef LOCAL_AGENTS_LA_FIELD_SNAPSHOT_HPP
#define LOCAL_AGENTS_LA_FIELD_SNAPSHOT_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/string.hpp>

#include <unordered_map>
#include <vector>

namespace godot {

// A MOMENT OF THE FIELD, HELD NATIVELY. The cells go device -> here -> device; a handle is the only
// thing that crosses into GDScript. One instance is one store: bind it to a device and its channel
// buffers, then capture/restore/serialize by handle.
class LAFieldSnapshot : public RefCounted {
	GDCLASS(LAFieldSnapshot, RefCounted);

public:
	// Serialised layout. Bumping it makes every older blob a refusal, never a reinterpretation.
	static constexpr int LAYOUT_VERSION = 1;

	// `bufs` is the driver's whole buffer table; only `names` are cells of state. `grid` is the box, which
	// is what makes a snapshot belong to one world rather than another.
	void bind(RenderingDevice *p_rd, const Dictionary &p_bufs, const PackedStringArray &p_names,
			int p_cell_count, Object *p_grid);
	int capture();
	// A snapshot of the bound world holding nothing: the state a restore has to be able to overwrite.
	int blank();
	bool restore(int p_handle);
	// Cells the field keeps a CPU copy of, re-seeded from the handle so no reader weighs two worlds.
	int apply_mirrors(int p_handle, Object *p_field);

	void ring(int p_cap);
	void drop(int p_handle);
	bool has(int p_handle) const;
	int size() const;
	// Bytes one capture of the bound world costs, so a caller with a memory budget can derive its depth.
	int64_t snapshot_bytes() const;

	int cell_count(int p_handle) const;
	PackedStringArray channels(int p_handle) const;
	String world_key(int p_handle) const;
	// Each channel's sum over the cells: what the world's conserved books are read off.
	Dictionary totals(int p_handle) const;
	// { cells: differing cell readings, channels: PackedStringArray of the channels they are in }.
	Dictionary compare(int p_a, int p_b) const;

	PackedByteArray serialize(int p_handle) const;
	int deserialize(const PackedByteArray &p_bytes);

protected:
	static void _bind_methods();

private:
	struct Snap {
		int cc = 0;
		String world_key;
		PackedStringArray names;
		PackedByteArray data; // names.size() * cc * 4, channel-major
	};

	static String world_key_of(Object *p_grid);
	const Snap *find(int p_handle) const;
	int store(Snap &&p_snap);
	int offset_of(const Snap &p_snap, const String &p_name) const;

	RenderingDevice *_rd = nullptr;
	PackedStringArray _names;
	std::vector<RID> _rids;
	int _cc = 0;
	String _world_key;

	std::unordered_map<int, Snap> _snaps;
	std::vector<int> _order;
	int _next = 1;
	int _cap = 0; // 0 keeps every handle until it is dropped
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_FIELD_SNAPSHOT_HPP
