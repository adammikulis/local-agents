#pragma once

#include "FieldRun.hpp"
#include "Plan.hpp"
#include "Snapshot.hpp"
#include "la/Device.hpp"
#include <map>
#include <memory>
#include <span>
#include <string>
#include <vector>

namespace lasim {

struct FieldIdentity {
	uint64_t snapshot = 0;
	uint64_t plan = 0;
	uint64_t kernels = 0;
	uint32_t loaded = 0;
};

struct ReducedRow {
	std::string key;
	double value = 0.0;
	bool present = false;
};

class FieldSession {
	la::Device &device;
	la::Snapshot state;
	la::Plan layout;
	FieldIdentity hashes;
	std::map<std::string, la::KernelId> kernels;
	std::vector<la::BufferId> buffers;
	std::vector<la::SetId> sets;
	std::vector<char> set_built;

	explicit FieldSession(la::Device &p_device) : device(p_device) {}
	bool initialize(const RunArgs &args, std::string &err);

public:
	~FieldSession();
	FieldSession(const FieldSession &) = delete;
	FieldSession &operator=(const FieldSession &) = delete;
	static std::unique_ptr<FieldSession> open(la::Device &device, const RunArgs &args, std::string &err);
	bool execute(uint32_t recorded_step, std::string &err);
	bool reductions(std::vector<ReducedRow> &out, std::string &err);
	bool read_buffer(const std::string &name, std::span<uint8_t> out, std::string &err);
	const la::Plan &plan() const { return layout; }
	const la::Snapshot &metadata() const { return state; }
	const FieldIdentity &identity() const { return hashes; }
};

}
