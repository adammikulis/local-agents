#ifndef LOCAL_AGENTS_LA_FIELD_DRIVER_HPP
#define LOCAL_AGENTS_LA_FIELD_DRIVER_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/core/binder_common.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/string.hpp>

#include <vector>

namespace godot {

// THE PER-STEP DRIVER. It takes the declared records and builds every push-constant block, dispatch
// table and fold shape itself; GDScript declares the records and binds the buffers.
class LAFieldDriver : public RefCounted {
	GDCLASS(LAFieldDriver, RefCounted);

public:
	void set_device(RenderingDevice *p_rd);

	void clear_buffers(const Array &p_bufs, int p_bytes);

	void run(int64_t p_cl, const RID &p_pipe, const Array &p_usets, const Array &p_pcs,
			const PackedInt32Array &p_workgroups, const Array &p_args,
			const PackedInt32Array &p_offsets, bool p_barrier);

	void step(const Array &p_passes, const PackedStringArray &p_names, const Dictionary &p_ctx,
			int p_cc, int p_groups, const Callable &p_probe);
	// A pass that must READ the device takes its own submit before the step records.
	void pre_step(const Array &p_passes, const Dictionary &p_ctx, int p_cc, int p_groups);
	// Can anything write matter or energy this step: a LIVE pass declaring MOVES_STATE, or the derive's
	// own live lithify step.
	bool moves_state(const Array &p_passes) const;

	// Consecutive records that advance on ONE time axis, as their own indices.
	static Array transport_groups(const Array &p_records);
	// Those groups plus the grain prologue's own slot: what a per-group buffer must hold.
	static int transport_group_count(const Array &p_records);

	void plan_transport(const Dictionary &p_plan);
	void run_peak(int64_t p_cl, int p_seed_workgroups, const Dictionary &p_step);
	int64_t run_transport(int64_t p_cl, const PackedInt32Array &p_peaks, const Dictionary &p_step,
			int p_seed_workgroups, int p_list_workgroups);
	void build_levels(int64_t p_cl, int p_group, int p_levels, const Dictionary &p_step);

	void plan_reduce(const Dictionary &p_plan);
	void run_reduce(int64_t p_cl, const PackedInt32Array &p_rows);
	Dictionary fold_reduce(const RID &p_partials);
	// The reduce plan as this driver built it: one push-constant block per row, the fold shape each
	// row's partials combine with, and the key each publishes under.
	Dictionary reduce_plan() const;

protected:
	static void _bind_methods();

private:
	// Dispatch tag of one kernel entry point: the value flux.glsl reads as `pass_id`, and the slot of
	// one record's block table.
	enum Slot {
		SLOT_OUTFLOW = 0,
		SLOT_GATHER = 1,
		SLOT_GRAIN = 2,
		SLOT_LIST_RESET = 3,
		SLOT_LIST_APPEND = 4,
		SLOT_LIST_ARGS = 5,
		SLOT_SW = 6,
		SLOT_FACE = 7,
		SLOT_MOMENTUM = 8,
		SLOT_LEVEL_SEED = 9,
		SLOT_LEVEL_RELAX = 10,
		SLOT_LEVEL_RESET = 11,
		SLOT_LEVEL_SCAN = 12,
		SLOT_LEVEL_SORT = 13,
		SLOT_LEVEL_PEAK = 14,
		SLOT_ACT_AGE = 15,
		SLOT_ACT_WAKE = 16,
		SLOT_ACT_MARK = 17,
		SLOT_ACT_WAKE_RESET = 18,
		SLOT_ACT_SEED = 19,
	};

	// How a reduce row's workgroup partials combine, derived from LAReduceRecords' own Op table.
	enum Fold {
		FOLD_SUM = 0,
		FOLD_MIN = 1,
		FOLD_MAX = 2,
		FOLD_SKIP = 3,
	};

	// One record's block, the slots it dispatches, where it sits on the time axes, and the process
	// whose switch decides whether it runs at all.
	struct Row {
		PackedByteArray block;
		uint32_t slots = 0;
		int group = 0;
		String label;
	};

	// Byte offsets inside a flux block, taken from the order the block was written in.
	struct Offsets {
		int pass = 0;
		int dt = 0;
		int sun = 0;
		int xuv = 0;
		int level = 0;
		int k = 0;
		int n = 0;
		int act_group = 0;
		int phi = 0;
		int grav = 0;
	};

	RenderingDevice *_rd = nullptr;

	RID _pipe;
	Array _row_sets;
	PackedInt32Array _row_live;   // 0 = this record's switch is off; it moves nothing this step
	Array _groups;
	RID _args;
	RID _wake_args;
	RID _grain_set;
	Array _list_sets;
	std::vector<Row> _rows;
	Row _grain;
	std::vector<Row> _lists;
	Offsets _off;
	int _queue_bin = 0;
	int _slots = 0;
	int _group_count = 1;
	int _flush_every = 4096;
	int _recorded = 0;

	RID _reduce_pipe;
	Array _reduce_sets;
	Array _reduce_pc;
	PackedInt32Array _folds;
	PackedStringArray _keys;
	int _reduce_groups = 0;

	PackedByteArray _scratch;
	// THE EQUATION OF STATE, restated inside the substep. Its kernel, bindings and block belong to the
	// derive pass; this holds only where in the block the list slot and the group's list base go.
	RID _eos_pipe;
	RID _eos_set;
	PackedByteArray _eos_pc;
	int _eos_slot_off = -1;
	int _eos_base_off = -1;
	int _eos_total = 0;

	int _args_offset(int p_group, int p_bin) const;
	Dictionary _off_last;         // pass label -> its switch was off when the last step ran
	// Which records the process set admits this step, read fresh: a switch may move between steps.
	void _refresh_live();
	bool _live(int p_row) const;
	void _encode(Row &p_dst, const Dictionary &p_row, int p_cc, int p_total, int p_bands, int p_group);
	void _build_levels(int64_t p_cl, int p_group, int p_levels);
	// Copies one record's block into the scratch and writes this dispatch's tag, level and substep.
	const PackedByteArray &_block(const Row &p_row, int p_slot, int p_level, int p_k, int p_n);
	void _stamp_step(const Dictionary &p_step);
	void _stamp_one(Row &p_row, float p_dt, const Vector3 &p_sun, float p_xuv, float p_phi,
			float p_grav);
	void _fire(int64_t p_cl, const RID &p_uset, const PackedByteArray &p_pc, const RID &p_args,
			int p_offset);
	void _fire_on(int64_t p_cl, const RID &p_pipe, const RID &p_uset, const PackedByteArray &p_pc,
			const RID &p_args, int p_offset);
	void _restate(int64_t p_cl, int p_group, int p_level);
	void _act(int64_t p_cl, const RID &p_uset, const Row &p_row, int p_slot, int p_group, int p_bin,
			int p_level);
	void _rebuild_active(int64_t p_cl, const RID &p_uset, const Row &p_row, int p_group, int p_level,
			bool p_take_wake);
	void _run_row(int64_t p_cl, int p_row, int p_level, int p_k, int p_n);
	void _run_slot(int64_t p_cl, int p_row, int p_slot, int p_level, int p_k, int p_n);
	int64_t _flush(int64_t p_cl);
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_FIELD_DRIVER_HPP
