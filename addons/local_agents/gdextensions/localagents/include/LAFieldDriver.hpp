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

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace godot {

// THE PER-STEP DRIVER, ONE PER DEVICE. It owns the compute list and every submit on it; it declares no
// row, no binding and no push-constant layout. Every record stays in GDScript, which hands the encoded
// blocks down. A dispatch reaches the device in as many submits as its measured cost asks, each an even
// sample of its workgroups (kernels3d/chunk.glsli).
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
		SLOT_LEVEL_SCAN = 8,
		SLOT_LEVEL_SORT = 9,
		SLOT_LEVEL_RESET = 10,
		SLOT_LEVEL_SEED = 11,
		SLOT_LEVEL_RELAX = 12,
		SLOT_GRAIN = 13,
		SLOT_ACT_SEED = 14,
		SLOT_ACT_WAKE_RESET = 15,
		SLOT_LIST_RESET = 16,
		SLOT_LIST_APPEND = 17,
		SLOT_LIST_ARGS = 18,
		SLOT_COUNT = 19,
	};

	// How a reduce row's workgroup partials combine. LAReduceRecords owns the op table; this is the
	// three shapes it folds into, so no operation code is declared twice.
	enum Fold {
		FOLD_SUM = 0,
		FOLD_MIN = 1,
		FOLD_MAX = 2,
		FOLD_SKIP = 3,
	};

	// LAW: Godot 4.7's Metal driver waits this long on a submit's fence, then carries on as if the work
	// were done (drivers/metal/rendering_device_driver_metal3.cpp, fence_wait: wait(1000)). Its Vulkan
	// and D3D12 drivers wait without limit.
	static constexpr int64_t METAL_FENCE_WAIT_MS = 1000;

	// The driver of one device, planning against that backend's own fence wait.
	static Ref<LAFieldDriver> on(RenderingDevice *p_rd);
	// The wait a rig plans against in place of the backend's.
	void set_wait_usec(double p_usec);
	double wait_usec() const;

	void open();
	void close();
	// The field now holds a state no kernel produced, so no cost measured on another state predicts it.
	void restart();
	// A direct dispatch covers p_workgroups; an indirect one's p_workgroups is the most its args can ask.
	// One set, or one cost key, serves every block.
	void run(const RID &p_pipe, const Array &p_usets, const Array &p_pcs, const PackedInt32Array &p_workgroups,
			const Array &p_args, const PackedInt32Array &p_offsets, bool p_barrier, const PackedStringArray &p_keys);
	void clear_buffers(const Array &p_bufs, int p_bytes);

	void step(const Array &p_passes, const PackedStringArray &p_names, const Dictionary &p_ctx,
			int p_cc, int p_groups, const Callable &p_probe);
	// A pass that must READ the device takes its own submit before the step records.
	void pre_step(const Array &p_passes, const Dictionary &p_ctx, int p_cc, int p_groups);
	// Can anything write matter or energy this step: a LIVE pass declaring MOVES_STATE, or the derive's
	// own live lithify step.
	bool moves_state(const Array &p_passes) const;

	void setup_transport(const Dictionary &p_plan);
	void run_transport(const PackedInt32Array &p_peaks, const Array &p_pc_rows, const Array &p_pc_grain,
			const Array &p_pc_lists, int p_seed_workgroups, int p_list_workgroups, const Dictionary &p_restate);
	void build_levels(int p_group, const Array &p_pc_rows, int p_levels);

	Dictionary fold_reduce(const RID &p_partials, const PackedInt32Array &p_folds,
			const PackedStringArray &p_keys, int p_groups);

	// Submits and the dispatches and classes they carried, refusals, submits planned past their target, the
	// longest submit (usec), and the wait.
	Dictionary ledger() const;
	// A pass's block with the chunk words appended: the Params block its kernel declares.
	static PackedByteArray dispatched_block(const PackedByteArray &p_pc, int64_t p_stride, int64_t p_phase);

protected:
	static void _bind_methods();

private:
	// One dispatch's measured cost: its latency floor, the longest one workgroup took alone (an indirect
	// dispatch's whole list is its smallest piece), and the last submit that carried it alone.
	struct Cost {
		bool known = false;
		bool indirect = false;
		double latency_usec = 0.0;
		double last_usec = 0.0;
		double last_groups = 0.0;
	};
	struct Carried {
		std::string key;
		double groups = 0.0;
	};

	RenderingDevice *_rd = nullptr;
	int64_t _cl = 0;
	bool _open = false;
	double _wait_usec = 0.0;
	std::unordered_map<std::string, Cost> _costs;
	std::vector<Carried> _carried;
	int64_t _submits = 0;
	int64_t _dispatches = 0;
	int64_t _classes = 0;
	int64_t _refused = 0;
	int64_t _over_target = 0;
	double _worst_usec = 0.0;
	PackedByteArray _out;

	RID _pipe;
	Array _row_sets;
	PackedInt32Array _row_group;
	PackedInt32Array _row_radiate;
	Array _rows;                  // the transport records this plan walks, in dispatch order
	PackedInt32Array _row_live;   // 0 = this record's switch is off; it moves nothing this step
	std::vector<std::string> _slot_keys;   // per owner (row, grain, list) and slot: its cost key
	Array _groups;
	RID _args;
	RID _wake_args;
	RID _grain_set;
	Array _list_sets;
	int _queue_bin = 0;
	int _slots = 0;
	int _group_count = 1;
	int64_t _capacity = 0;        // workgroups over every cell a list can hold
	int _level_off = 0;
	int _k_off = 0;
	int _n_off = 0;

	PackedByteArray _scratch;
	// THE EQUATION OF STATE, restated inside the substep. Its kernel, bindings and block belong to the
	// derive pass; this holds only where in the block the list slot and the group's list base go.
	RID _eos_pipe;
	RID _eos_set;
	PackedByteArray _eos_pc;
	int _eos_slot_off = -1;
	int _eos_base_off = -1;
	int _eos_total = 0;

	Dictionary _off_last;         // pass label -> its switch was off when the last step ran

	bool _bounded() const;
	// A dispatch's submit target: as many times shorter than the wait as it is longer than its latency floor.
	double _target(const Cost &p_cost) const;
	double _pred(const Cost &p_cost, double p_groups) const;
	// The open submit's predicted usec and target, with `p_more` more workgroups of `p_key` in it.
	void _load(const std::string &p_key, double p_more, double &r_pred, double &r_target) const;
	bool _fits(const std::string &p_key, double p_groups) const;
	void _submit();
	void _flush();
	void _learn(double p_usec);
	bool _admit(const std::string &p_key, double p_groups, bool p_indirect);
	void _emit(const RID &p_pipe, const RID &p_uset, const PackedByteArray &p_pc, int64_t p_stride,
			int64_t p_phase, int64_t p_groups, const RID &p_args, int p_offset);
	void _plan(const std::string &p_key, const RID &p_pipe, const RID &p_uset, const PackedByteArray &p_pc,
			int64_t p_groups, bool p_barrier);
	void _plan_indirect(const std::string &p_key, const RID &p_pipe, const RID &p_uset,
			const PackedByteArray &p_pc, const RID &p_args, int p_offset, int64_t p_capacity, bool p_barrier);

	int _args_offset(int p_group, int p_bin) const;
	bool _live(int p_row) const;
	// Owners: a row by its index, the grain prologue at _rows.size(), list r past it.
	const std::string &_key(int p_owner, int p_slot) const;
	// Copies one block into the scratch and writes this substep's level, index and count into it.
	const PackedByteArray &_block(const Array &p_table, int p_slot, int p_level, int p_k, int p_n);
	void _restate(int p_group, int p_level);
	void _act(int p_owner, const RID &p_uset, const Array &p_table, int p_slot, int p_group, int p_level,
			int p_bin);
	void _rebuild_active(int p_owner, const RID &p_uset, const Array &p_table, int p_group, int p_level,
			bool p_take_wake);
	void _run_row(int p_row, const Array &p_pc_rows, int p_level, int p_k, int p_n);
	void _run_slot(int p_row, const Array &p_pc_rows, int p_slot, int p_level, int p_k, int p_n);
};

} // namespace godot

VARIANT_ENUM_CAST(LAFieldDriver::Slot);
VARIANT_ENUM_CAST(LAFieldDriver::Fold);

#endif // LOCAL_AGENTS_LA_FIELD_DRIVER_HPP
