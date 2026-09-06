#include "FieldRun.hpp"

#include "Plan.hpp"
#include "Snapshot.hpp"
#include "la/Device.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace lasim {
namespace {

// FNV-1a over a file's bytes: the manifest's name for the content a run was given.
bool content_hash(const std::string &path, uint64_t &out) {
	std::FILE *f = std::fopen(path.c_str(), "rb");
	if (f == nullptr) { return false; }
	uint64_t h = 1469598103934665603ULL;
	unsigned char buf[65536];
	size_t n = 0;
	while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) {
		for (size_t i = 0; i < n; ++i) {
			h ^= uint64_t(buf[i]);
			h *= 1099511628211ULL;
		}
	}
	std::fclose(f);
	out = h;
	return true;
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

int field_run(la::Device &dev, const RunArgs &args) {
	std::string err;
	la::Snapshot snap;
	if (!la::Snapshot::read(args.snapshot, snap, err)) {
		std::fprintf(stderr, "lasim: %s\n", err.c_str());
		return 2;
	}
	la::Plan plan;
	if (!la::Plan::read(args.plan, plan, err)) {
		std::fprintf(stderr, "lasim: %s\n", err.c_str());
		return 2;
	}
	la::WorldKey world;
	if (!la::WorldKey::parse(snap.world_key, world, err)) {
		std::fprintf(stderr, "lasim: %s\n", err.c_str());
		return 2;
	}
	if (world.cell_count != int64_t(snap.cells)) {
		std::fprintf(stderr, "lasim: the snapshot's world key names %lld cells and it carries %u.\n",
				(long long)world.cell_count, snap.cells);
		return 2;
	}
	if (plan.cells != snap.cells) {
		std::fprintf(stderr, "lasim: the plan holds %u cells and the snapshot %u.\n", plan.cells,
				snap.cells);
		return 2;
	}
	if (args.steps == 0 || args.steps > plan.steps.size()) {
		std::fprintf(stderr, "lasim: the plan records %zu steps; --step %u asks for another run.\n",
				plan.steps.size(), args.steps);
		return 2;
	}

	// EVERY KERNEL THE PLAN DISPATCHES, taken off the plan itself: the recorded steps are the one
	// declaration of which passes this run is, so nothing on the command line restates them.
	std::vector<std::string> want_kernels;
	for (const std::vector<la::PlanDispatch> &step : plan.steps) {
		for (const la::PlanDispatch &d : step) {
			if (std::find(want_kernels.begin(), want_kernels.end(), d.kernel) == want_kernels.end()) {
				want_kernels.push_back(d.kernel);
			}
		}
	}
	if (want_kernels.empty()) {
		std::fprintf(stderr, "lasim: the plan records no dispatch, so this run steps nothing.\n");
		return 2;
	}
	std::string pass_list;
	for (const std::string &k : want_kernels) {
		if (!pass_list.empty()) { pass_list += ","; }
		pass_list += k;
	}

	std::map<std::string, la::KernelId> kernels;
	for (const std::string &name : want_kernels) {
		if (!dev.has_kernel(name)) {
			std::fprintf(stderr, "lasim: the blob carries no kernel named %s.\n", name.c_str());
			return 2;
		}
		la::KernelId k = dev.kernel(name);
		if (!dev.build(k, err)) {
			std::fprintf(stderr, "lasim: %s would not build: %s\n", name.c_str(), err.c_str());
			return 2;
		}
		kernels.emplace(name, k);
	}

	// ONE DEVICE BUFFER PER BUFFER THE PLAN NAMES, at the length the Godot pass allocated.
	std::vector<la::BufferId> buffers;
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
		if (at < 0) { continue; }
		dev.upload(buffers[size_t(at)], 0, snap.data.data() + size_t(i) * size_t(snap.cells),
				size_t(snap.cells) * 4u);
		loaded++;
	}

	// THE SETS THE PASSES BUILT, pair for pair: a reduce row aliases one buffer into several slots, so
	// this is never rebuilt from the kernel's binding list.
	// A set for a kernel this run does not dispatch is not built; a dispatch that names one is refused.
	std::vector<la::SetId> sets;
	std::vector<char> set_built;
	for (size_t s = 0; s < plan.sets.size(); ++s) {
		const auto k = kernels.find(plan.sets[s].kernel);
		if (k == kernels.end()) {
			sets.push_back(la::SetId{});
			set_built.push_back(0);
			continue;
		}
		std::vector<std::pair<uint32_t, la::BufferId>> bound;
		for (const la::PlanBind &b : plan.sets[s].binds) {
			if (b.buffer >= buffers.size()) {
				std::fprintf(stderr, "lasim: set %zu names buffer %u of %zu.\n", s, b.buffer,
						buffers.size());
				return 2;
			}
			bound.emplace_back(b.binding, buffers[b.buffer]);
		}
		sets.push_back(dev.make_set(k->second, bound));
		set_built.push_back(1);
	}

	uint64_t snap_hash = 0;
	uint64_t plan_hash = 0;
	uint64_t blob_hash = 0;
	content_hash(args.snapshot, snap_hash);
	content_hash(args.plan, plan_hash);
	content_hash(args.blob, blob_hash);
	std::printf("LASIM_RUN={\"device\":\"%s\",\"backend\":\"%s\",\"kernels\":\"%016llx\","
				"\"snapshot\":\"%016llx\",\"plan\":\"%016llx\",\"passes\":\"%s\",\"steps\":%u,"
				"\"cells\":%u,\"world\":\"%s\",\"channels_loaded\":%u}\n",
			dev.name(), dev.backend() == la::Backend::Metal ? "metal" : "vulkan",
			(unsigned long long)blob_hash, (unsigned long long)snap_hash, (unsigned long long)plan_hash,
			pass_list.c_str(), args.steps, snap.cells, snap.world_key.c_str(), loaded);

	for (uint32_t s = 0; s < args.steps; ++s) {
		la::List list = dev.begin();
		for (const la::PlanDispatch &d : plan.steps[s]) {
			la::KernelId k = kernels[d.kernel];
			if (d.push.size() != size_t(dev.push_size(k))) {
				std::fprintf(stderr, "lasim: %s declares a %u-byte push block; the plan recorded %zu.\n",
						d.kernel.c_str(), dev.push_size(k), d.push.size());
				return 2;
			}
			if (d.set >= sets.size() || set_built[d.set] == 0) {
				std::fprintf(stderr, "lasim: a %s dispatch names set %u, which this run did not build.\n",
						d.kernel.c_str(), d.set);
				return 2;
			}
			dev.bind(list, k, sets[d.set]);
			if (!d.push.empty()) { dev.push(list, d.push.data(), d.push.size()); }
			dev.dispatch(list, d.groups);
			dev.barrier(list);
			dev.mark(list, d.kernel.c_str());
		}
		dev.wait(dev.submit(std::move(list)));
	}

	// The partials, folded in float64 in the plan's own row order.
	std::vector<double> row_value(plan.rows.size(), 0.0);
	std::vector<char> row_present(plan.rows.size(), 0);
	if (!plan.rows.empty()) {
		const int partials = plan.at("reduce_partials");
		if (partials < 0) {
			std::fprintf(stderr, "lasim: the plan names reduce rows and no partials buffer.\n");
			return 2;
		}
		std::vector<float> parts(size_t(plan.reduce_groups) * plan.rows.size(), 0.0f);
		dev.download(buffers[size_t(partials)], 0, parts.data(), parts.size() * 4u);
		for (size_t r = 0; r < plan.rows.size(); ++r) {
			bool present = false;
			const double v = fold_rows(parts, plan.reduce_groups, uint32_t(r), plan.rows[r].fold, present);
			row_value[r] = v;
			row_present[r] = present ? 1 : 0;
		}
	}

	if (args.report) {
		std::string out = "SIM_REPORT={";
		bool first = true;
		for (size_t r = 0; r < plan.rows.size(); ++r) {
			if (row_present[r] == 0) { continue; }
			char buf[512];
			std::snprintf(buf, sizeof(buf), "%s\"%s\":%.17g", first ? "" : ",", plan.rows[r].key.c_str(),
					row_value[r]);
			out += buf;
			first = false;
		}
		out += "}";
		std::printf("%s\n", out.c_str());
	}

	// EVERY f32 BUFFER THE PLAN NAMED, read back into the snapshot layout: the derived mirrors compare
	// as bytes against the ones the Godot pass wrote.
	if (!args.mirrors.empty()) {
		la::Snapshot mirror;
		mirror.version = 1;
		mirror.cells = snap.cells;
		mirror.world_key = snap.world_key;
		std::vector<float> cell(snap.cells, 0.0f);
		for (size_t i = 0; i < plan.buffers.size(); ++i) {
			const la::PlanBuffer &b = plan.buffers[i];
			if (b.kind != 0u || b.elems < snap.cells) { continue; }
			dev.download(buffers[i], 0, cell.data(), size_t(snap.cells) * 4u);
			mirror.names.push_back(b.name);
			mirror.data.insert(mirror.data.end(), cell.begin(), cell.end());
		}
		if (!la::Snapshot::write(args.mirrors, mirror, err)) {
			std::fprintf(stderr, "lasim: %s\n", err.c_str());
			return 2;
		}
	}

	for (size_t s = 0; s < sets.size(); ++s) {
		if (set_built[s] != 0) { dev.destroy_set(sets[s]); }
	}
	for (la::BufferId b : buffers) { dev.destroy_buffer(b); }
	return 0;
}

} // namespace lasim
