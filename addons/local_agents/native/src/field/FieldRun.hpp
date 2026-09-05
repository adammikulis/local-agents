#pragma once

#include <string>

namespace la {
class Device;
}

namespace lasim {

struct RunArgs {
	std::string snapshot;
	std::string plan;
	std::string passes;
	std::string mirrors; // where the derived channels are written back, LAFieldSnapshot's own layout
	std::string blob;
	uint32_t steps = 1;
	bool report = false;
};

int field_run(la::Device &dev, const RunArgs &args);

} // namespace lasim
