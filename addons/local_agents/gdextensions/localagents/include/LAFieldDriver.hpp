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

namespace godot {

// THE PER-STEP DRIVER. It issues the compute list; it declares no row, no binding and no push-constant
// layout. Every record stays in GDScript, which hands the encoded blocks down.
class LAFieldDriver : public RefCounted {
	GDCLASS(LAFieldDriver, RefCounted);

public:
	// Slots of one row's push-constant table. A slot with no block is a pass that row does not run.
	enum Slot {
		SLOT_OUTFLOW = 0,
		SLOT_GATHER = 1,
		SLOT_SW = 2,
		SLOT_FACE = 3,
		SLOT_MOMENTUM = 4,
		SLOT_ACT_AGE = 5,
		SLOT_ACT_WAKE = 6,
		SLOT_ACT_MARK = 7,
		SLOT_SCAN = 8,
		SLOT_COMPACT = 9,
		SLOT_GRAIN = 10,
		SLOT_ACT_SEED = 11,
		SLOT_ACT_WAKE_RESET = 12,
		SLOT_LIST_RESET = 13,
		SLOT_LIST_APPEND = 14,
		SLOT_LIST_ARGS = 15,
		SLOT_STEP_DT = 16,
		SLOT_COUNT = 17,
	};

	// How a reduce row's workgroup partials combine. LAReduceRecords owns the op table; this is the
	// three shapes it folds into, so no operation code is declared twice.
	enum Fold {
		FOLD_SUM = 0,
		FOLD_MIN = 1,
		FOLD_MAX = 2,
		FOLD_SKIP = 3,
	};

	void set_device(RenderingDevice *p_rd);

	void clear_buffers(const Array &p_bufs, int p_bytes);

	void run(int64_t p_cl, const RID &p_pipe, const Array &p_usets, const Array &p_pcs,
			const PackedInt32Array &p_workgroups, const Array &p_args,
			const PackedInt32Array &p_offsets, bool p_barrier);

	void step(const Array &p_passes, const PackedStringArray &p_names, const Dictionary &p_ctx,
			int p_cc, int p_groups, const Callable &p_probe);

	void setup_transport(const Dictionary &p_plan);
	int64_t run_transport(int64_t p_cl, const Array &p_pc_rows, const Array &p_pc_grain,
			const Array &p_pc_lists, int p_seed_workgroups, int p_list_workgroups,
			const Dictionary &p_restate, const PackedByteArray &p_hz_pc);
	// The last acoustic solve's residual over its own source, and the iterations it took.
	Dictionary acoustic_reading() const;
	// THE STEP THE LISTED CELLS AFFORD, seconds: every row states what its own cells can be
	// integrated over, reduced into p_dt_buf on the device, and the shortest is read back here.
	double step_seconds(const RID &p_dt_buf, const Array &p_pc_rows, const Array &p_pc_grain,
			int p_seed_workgroups);

	Dictionary fold_reduce(const RID &p_partials, const PackedInt32Array &p_folds,
			const PackedStringArray &p_keys, int p_groups);

protected:
	static void _bind_methods();

private:
	RenderingDevice *_rd = nullptr;

	RID _pipe;
	Array _row_sets;
	PackedInt32Array _row_group;
	PackedInt32Array _row_radiate;
	Array _groups;
	RID _args;
	RID _wake_args;
	RID _grain_set;
	Array _list_sets;
	// The acoustic solve's own pipeline and uniform set: one assemble dispatch between the face
	// predictor and the momentum close, with the solve itself outside any compute list.
	RID _hz_pipe;
	RID _hz_set;
	RID _hz_comp;
	RID _hz_cond;
	RID _hz_rhs;
	RID _hz_p;
	RID _slot_off;
	RID _nbr;
	int _cc = 0;
	double _hz_tol = 0.0;
	int _hz_max_iter = 0;
	double _hz_dt_s = 0.0;
	float _hz_dt_s_f = 0.0f;
	double _hz_residual = 0.0;
	int _hz_iterations = 0;
	int _slots = 0;
	int _group_count = 1;
	int _flush_every = 4096;
	int _recorded = 0;

	PackedByteArray _scratch;
	// THE EQUATION OF STATE, restated inside the substep. Its kernel, bindings and block belong to the
	// derive pass; this holds only where in the block the list slot and the group's list base go.
	RID _eos_pipe;
	RID _eos_set;
	PackedByteArray _eos_pc;
	int _eos_slot_off = -1;
	int _eos_base_off = -1;
	int _eos_total = 0;

	int _args_offset(int p_group) const;
	const PackedByteArray &_block(const Array &p_table, int p_slot);
	void _fire(int64_t p_cl, const RID &p_uset, const PackedByteArray &p_pc, const RID &p_args,
			int p_offset);
	void _fire_on(int64_t p_cl, const RID &p_pipe, const RID &p_uset, const PackedByteArray &p_pc,
			const RID &p_args, int p_offset);
	void _restate(int64_t p_cl, int p_group);
	void _act(int64_t p_cl, const RID &p_uset, const Array &p_table, int p_slot, int p_group);
	void _rebuild_active(int64_t p_cl, const RID &p_uset, const Array &p_table, int p_group,
			bool p_take_wake);
	void _run_row(int64_t p_cl, int p_row, const Array &p_pc_rows);
	void _run_slot(int64_t p_cl, int p_row, const Array &p_pc_rows, int p_slot);
	int64_t _flush(int64_t p_cl);
	void _solve_acoustic();
};

} // namespace godot

VARIANT_ENUM_CAST(LAFieldDriver::Slot);
VARIANT_ENUM_CAST(LAFieldDriver::Fold);

#endif // LOCAL_AGENTS_LA_FIELD_DRIVER_HPP
