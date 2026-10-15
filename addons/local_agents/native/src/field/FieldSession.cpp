#include "FieldSession.hpp"
#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <limits>
#include <set>

namespace lasim {
namespace {

bool fail(std::string &err, const char *format, ...) {
	va_list args, copy;
	va_start(args, format);
	va_copy(copy, args);
	const int size = std::vsnprintf(nullptr, 0, format, args);
	va_end(args);
	std::vector<char> text(size > 0 ? size_t(size) + 1 : 1, 0);
	std::vsnprintf(text.data(), text.size(), format, copy);
	va_end(copy);
	err = text.data();
	return false;
}

std::vector<std::string> split_commas(const std::string &s) {
	std::vector<std::string> out;
	std::string cur;
	for (char c : s) {
		if (c == ',') {
			if (!cur.empty()) { out.push_back(cur); }
			cur.clear();
		} else {
			cur.push_back(c);
		}
	}
	if (!cur.empty()) { out.push_back(cur); }
	return out;
}

// The kernel a pass name dispatches. A pass the plan does not carry is a pass this run cannot make.
const char *kernel_of(const std::string &pass) {
	if (pass == "derive") { return "state_derive"; }
	if (pass == "reduce") { return "reduce"; }
	return nullptr;
}

double fold_rows(const std::vector<float> &parts, uint32_t groups, uint32_t row, uint32_t fold,
		bool &present) {
	present = false;
	// A LATCH row writes a reference, never a partial: it publishes nothing.
	if (fold == la::FoldSkip) { return 0.0; }
	const size_t base = size_t(row) * size_t(groups);
	if (base + groups > parts.size()) { return 0.0; }
	double acc = fold == la::FoldMin ? std::numeric_limits<double>::infinity()
									 : (fold == la::FoldMax ? -std::numeric_limits<double>::infinity() : 0.0);
	for (uint32_t g = 0; g < groups; ++g) {
		const double x = double(parts[base + g]);
		if (fold == la::FoldMin) {
			acc = x < acc ? x : acc;
		} else if (fold == la::FoldMax) {
			acc = x > acc ? x : acc;
		} else {
			acc += x;
		}
	}
	// A MIN/MAX lane that kept no cell holds its infinite identity: no cell anywhere is no measurement.
	if (fold == la::FoldMin && acc == std::numeric_limits<double>::infinity()) { return 0.0; }
	if (fold == la::FoldMax && acc == -std::numeric_limits<double>::infinity()) { return 0.0; }
	present = true;
	return acc;
}

} // namespace

std::unique_ptr<FieldSession> FieldSession::open(la::Device &device, const RunArgs &args, std::string &err) {
	std::unique_ptr<FieldSession> session(new FieldSession(device));
	if (!session->initialize(args, err)) { return nullptr; }
	return session;
}

FieldSession::~FieldSession() {
	for (size_t i = 0; i < sets.size(); ++i) {
		if (set_built[i]) { device.destroy_set(sets[i]); }
	}
	for (la::BufferId buffer : buffers) { device.destroy_buffer(buffer); }
}

bool FieldSession::initialize(const RunArgs &args, std::string &err) {
	la::Device &dev = device;
	la::Snapshot &snap = state;
	if (!la::Snapshot::read(args.snapshot, snap, err)) {
		return fail(err, "%s\n", err.c_str());
	}
	la::Plan &plan = layout;
	if (!la::Plan::read(args.plan, plan, err)) {
		return fail(err, "%s\n", err.c_str());
	}
	la::WorldKey world;
	if (!la::WorldKey::parse(snap.world_key, world, err)) {
		return fail(err, "%s\n", err.c_str());
	}
	if (world.cell_count != int64_t(snap.cells)) {
		return fail(err, "the snapshot's world key names %lld cells and it carries %u.\n",
				(long long)world.cell_count, snap.cells);
	}
	if (plan.cells != snap.cells) {
		return fail(err, "the plan holds %u cells and the snapshot %u.\n", plan.cells,
				snap.cells);
	}
	if (args.steps == 0 || args.steps > plan.steps.size()) {
		return fail(err, "the plan records %zu steps; --steps %u asks for another run.\n",
				plan.steps.size(), args.steps);
	}

	if (snap.cells == 0 || snap.names.empty()) { return fail(err, "empty field snapshot"); }
	std::set<std::string> unique;
	for (const la::PlanBuffer &buffer : plan.buffers) {
		if (!unique.insert(buffer.name).second) { return fail(err, "duplicate plan buffer"); }
	}
	unique.clear();
	for (const std::string &name : snap.names) {
		if (!unique.insert(name).second) { return fail(err, "duplicate snapshot channel"); }
	}
	if (!plan.rows.empty() && plan.reduce_groups == 0) { return fail(err, "no reduction groups"); }
	for (const la::PlanRow &row : plan.rows) {
		if (row.fold > la::FoldSkip) { return fail(err, "unknown reduction fold"); }
	}
	for (const std::string &name : snap.names) {
		const int at = plan.at(name);
		if (at < 0 || plan.buffers[size_t(at)].kind != 0 || plan.buffers[size_t(at)].elems < snap.cells) {
			return fail(err, "snapshot channel has no compatible resident buffer: %s", name.c_str());
		}
	}
	if (!plan.rows.empty()) {
		const int at = plan.at("reduce_partials");
		const uint64_t elements = uint64_t(plan.reduce_groups) * plan.rows.size();
		if (at < 0 || plan.buffers[size_t(at)].kind != 0 || elements > plan.buffers[size_t(at)].elems) {
			return fail(err, "reduction rows have no complete partial buffer");
		}
	}
	const std::vector<std::string> passes = split_commas(args.passes);
	if (passes.empty()) { return fail(err, "no field passes selected"); }
	std::vector<std::string> want_kernels;
	for (const std::string &p : passes) {
		const char *k = kernel_of(p);
		if (k == nullptr) {
			return fail(err, "no pass named '%s'.\n", p.c_str());
		}
		want_kernels.emplace_back(k);
	}
	// Every dispatch the plan records must be one of the passes asked for, or the run is not the run named.
	for (const std::vector<la::PlanDispatch> &step : plan.steps) {
		for (const la::PlanDispatch &d : step) {
			if (std::find(want_kernels.begin(), want_kernels.end(), d.kernel) == want_kernels.end()) {
				return fail(err, "the plan dispatches '%s', which --passes %s does not name.\n",
						d.kernel.c_str(), args.passes.c_str());
			}
		}
	}

	for (const std::string &name : want_kernels) {
		if (!dev.has_kernel(name)) {
			return fail(err, "the blob carries no kernel named %s.\n", name.c_str());
		}
		la::KernelId k = dev.kernel(name);
		if (!dev.build(k, err)) {
			return fail(err, "%s would not build: %s\n", name.c_str(), err.c_str());
		}
		kernels.emplace(name, k);
	}

	for (const auto &step : plan.steps) {
		for (const la::PlanDispatch &dispatch : step) {
			const auto kernel = kernels.find(dispatch.kernel);
			if (kernel == kernels.end() || dispatch.set >= plan.sets.size()
					|| plan.sets[dispatch.set].kernel != dispatch.kernel || dispatch.groups == 0
					|| dispatch.push.size() != dev.push_size(kernel->second)) {
				return fail(err, "invalid recorded dispatch for %s", dispatch.kernel.c_str());
			}
		}
	}

	// ONE DEVICE BUFFER PER BUFFER THE PLAN NAMES, at the length the Godot pass allocated.
	for (const la::PlanBuffer &pb : plan.buffers) {
		const size_t bytes = std::max<size_t>(pb.bytes.size(), 4u);
		buffers.push_back(dev.create_buffer(bytes, la::Usage::Storage,
				pb.bytes.empty() ? nullptr : pb.bytes.data()));
	}

	// THE SNAPSHOT IS THE STATE: every channel it carries overwrites the plan's copy of that buffer, so
	// a run is of the world the snapshot holds and not of the world the plan was recorded on.
	uint32_t loaded = 0;
	for (size_t i = 0; i < snap.names.size(); ++i) {
		const int at = plan.at(snap.names[i]);
		dev.upload(buffers[size_t(at)], 0, snap.data.data() + size_t(i) * size_t(snap.cells),
				size_t(snap.cells) * 4u);
		loaded++;
	}

	// THE SETS THE PASSES BUILT, pair for pair: a reduce row aliases one buffer into several slots, so
	// this is never rebuilt from the kernel's binding list.
	// A set for a kernel this run does not dispatch is not built; a dispatch that names one is refused.
	for (size_t s = 0; s < plan.sets.size(); ++s) {
		const auto k = kernels.find(plan.sets[s].kernel);
		if (k == kernels.end()) {
			sets.push_back(la::SetId{});
			set_built.push_back(0);
			continue;
		}
		std::vector<std::pair<uint32_t, la::BufferId>> bound;
		std::set<uint32_t> seen;
		for (const la::PlanBind &b : plan.sets[s].binds) {
			if (b.buffer >= buffers.size()) {
				return fail(err, "set %zu names buffer %u of %zu.\n", s, b.buffer,
						buffers.size());
			}
			if (!seen.insert(b.binding).second || !dev.declares(k->second, b.binding)) {
				return fail(err, "invalid descriptor binding");
			}
			bound.emplace_back(b.binding, buffers[b.buffer]);
		}
		if (seen.size() != dev.bindings_of(k->second).size()) {
			return fail(err, "incomplete descriptor set");
		}
		sets.push_back(dev.make_set(k->second, bound));
		set_built.push_back(1);
	}

	hashes.snapshot = snap.content_hash;
	hashes.plan = plan.content_hash;
	hashes.kernels = device.kernel_blob_hash();

	hashes.loaded = loaded;
	state.data.clear();
	state.data.shrink_to_fit();
	for (la::PlanBuffer &buffer : layout.buffers) {
		buffer.bytes.clear();
		buffer.bytes.shrink_to_fit();
	}
	return true;

}

bool FieldSession::execute(uint32_t recorded_step, std::string &err) {
	if (recorded_step >= layout.steps.size()) { return fail(err, "recorded step is absent"); }
	la::List list = device.begin();
	for (const la::PlanDispatch &dispatch : layout.steps[recorded_step]) {
		device.bind(list, kernels.at(dispatch.kernel), sets[dispatch.set]);
		if (!dispatch.push.empty()) { device.push(list, dispatch.push.data(), dispatch.push.size()); }
		device.dispatch(list, dispatch.groups);
		device.barrier(list);
		device.mark(list, dispatch.kernel.c_str());
	}
	device.wait(device.submit(std::move(list)));
	return true;
}

bool FieldSession::read_buffer(const std::string &name, std::span<uint8_t> out, std::string &err) {
	const int at = layout.at(name);
	if (at < 0 || out.size() > size_t(layout.buffers[size_t(at)].elems) * 4) {
		return fail(err, "invalid buffer read: %s", name.c_str());
	}
	if (!out.empty()) { device.download(buffers[size_t(at)], 0, out.data(), out.size()); }
	return true;
}

bool FieldSession::reductions(std::vector<ReducedRow> &out, std::string &err) {
	out.clear();
	if (layout.rows.empty()) { return true; }
	std::vector<float> parts(size_t(layout.reduce_groups) * layout.rows.size());
	if (!read_buffer("reduce_partials", std::span<uint8_t>(reinterpret_cast<uint8_t *>(parts.data()),
			parts.size() * sizeof(float)), err)) { return false; }
	for (size_t row = 0; row < layout.rows.size(); ++row) {
		bool present = false;
		const double value = fold_rows(parts, layout.reduce_groups, uint32_t(row), layout.rows[row].fold, present);
		out.push_back({layout.rows[row].key, value, present});
	}
	return true;
}

} // namespace lasim
