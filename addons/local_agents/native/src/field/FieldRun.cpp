#include "FieldRun.hpp"
#include "FieldSession.hpp"
#include <cmath>
#include <cstdio>

namespace lasim {

int field_run(la::Device &dev, const RunArgs &args) {
	std::string err;
	auto session = FieldSession::open(dev, args, err);
	if (!session) {
		std::fprintf(stderr, "lasim: %s\n", err.c_str());
		return 2;
	}
	const auto &hash = session->identity();
	const auto &metadata = session->metadata();
	std::printf("LASIM_RUN={\"device\":\"%s\",\"backend\":\"%s\",\"kernels\":\"%016llx\","
			"\"snapshot\":\"%016llx\",\"plan\":\"%016llx\",\"passes\":\"%s\",\"steps\":%u,"
			"\"cells\":%u,\"world\":\"%s\",\"channels_loaded\":%u}\n",
			dev.name(), dev.backend() == la::Backend::Metal ? "metal" : "vulkan",
			(unsigned long long)hash.kernels, (unsigned long long)hash.snapshot, (unsigned long long)hash.plan,
			args.passes.c_str(), args.steps, metadata.cells, metadata.world_key.c_str(), hash.loaded);
	for (uint32_t step = 0; step < args.steps; ++step) {
		if (!session->execute(step, err)) {
			std::fprintf(stderr, "lasim: %s\n", err.c_str());
			return 2;
		}
	}
	std::vector<ReducedRow> rows;
	if (!session->reductions(rows, err)) {
		std::fprintf(stderr, "lasim: %s\n", err.c_str());
		return 2;
	}
	if (args.report) {
		std::string report = "SIM_REPORT={";
		bool first = true;
		for (const ReducedRow &row : rows) {
			if (!row.present) { continue; }
			char value[64];
			if (std::isfinite(row.value)) { std::snprintf(value, sizeof(value), "%.17g", row.value); }
			else { std::snprintf(value, sizeof(value), "null"); }
			report += (first ? "" : ",") + std::string("\"") + row.key + "\":" + value;
			first = false;
		}
		report += "}";
		std::printf("%s\n", report.c_str());
	}
	if (!args.mirrors.empty()) {
		la::Snapshot mirror;
		mirror.version = 1;
		mirror.cells = metadata.cells;
		mirror.world_key = metadata.world_key;
		for (const la::PlanBuffer &buffer : session->plan().buffers) {
			if (buffer.kind != 0 || buffer.elems != metadata.cells) { continue; }
			const size_t offset = mirror.data.size();
			mirror.data.resize(offset + metadata.cells);
			if (!session->read_buffer(buffer.name,
					std::span<uint8_t>(reinterpret_cast<uint8_t *>(mirror.data.data() + offset),
						size_t(metadata.cells) * sizeof(float)), err)) {
				std::fprintf(stderr, "lasim: %s\n", err.c_str());
				return 2;
			}
			mirror.names.push_back(buffer.name);
		}
		if (!la::Snapshot::write(args.mirrors, mirror, err)) {
			std::fprintf(stderr, "lasim: %s\n", err.c_str());
			return 2;
		}
	}
	return 0;
}

} // namespace lasim
