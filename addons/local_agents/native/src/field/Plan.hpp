#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace la {

// THE PLAN THE GODOT DRIVER PRODUCED, recorded rather than rebuilt. A reduce row aliases one buffer
// into several slots, so a set is a list of pairs and not a map from binding to buffer. Layout 1:
//   'LAPL', u32 version, u32 cell_count, u32 reduce_groups
//   u32 buffers { u32 len, name, u32 elems, u32 kind(0 f32 / 1 other), elems*4 bytes }
//   u32 sets    { u32 len, kernel, u32 entries { u32 binding, u32 buffer_index } }
//   u32 steps   { u32 dispatches { u32 len, kernel, u32 set_index, u32 groups, u32 push_len, push } }
//   u32 rows    { u32 len, key, u32 fold(0 sum / 1 min / 2 max / 3 skip) }
struct PlanBuffer {
	std::string name;
	uint32_t elems = 0;
	uint32_t kind = 0;
	std::vector<uint8_t> bytes;
};

struct PlanBind {
	uint32_t binding = 0;
	uint32_t buffer = 0;
};

struct PlanSet {
	std::string kernel;
	std::vector<PlanBind> binds;
};

struct PlanDispatch {
	std::string kernel;
	uint32_t set = 0;
	uint32_t groups = 0;
	std::vector<uint8_t> push;
};

struct PlanRow {
	std::string key;
	uint32_t fold = 0;
};

enum Fold : uint32_t { FoldSum = 0, FoldMin = 1, FoldMax = 2, FoldSkip = 3 };

struct Plan {
	uint64_t content_hash = 0;
	uint32_t version = 0;
	uint32_t cells = 0;
	uint32_t reduce_groups = 0;
	std::vector<PlanBuffer> buffers;
	std::vector<PlanSet> sets;
	std::vector<std::vector<PlanDispatch>> steps;
	std::vector<PlanRow> rows;

	static bool read(const std::string &path, Plan &out, std::string &err);

	// Index of a named buffer, or -1.
	int at(const std::string &name) const;
};

} // namespace la
