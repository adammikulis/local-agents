#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace la {

// One storage buffer a kernel declares. `binding` is the GLSL layout(binding=N); `slot` is the dense
// argument-buffer index lakc assigned it, ascending in binding order, which is the [[id(slot)]] the MSL
// carries. Dense, because a sparse [[id]] leaves the byte offset of a member to Metal's struct layout.
struct BlobBinding {
	uint32_t set = 0;
	uint32_t binding = 0;
	uint32_t slot = 0;
	std::string name;
};

struct BlobKernel {
	std::string name;
	std::string entry;
	std::string msl;
	std::vector<uint32_t> spirv;
	uint32_t local[3] = {1, 1, 1};
	uint32_t push_size = 0;
	uint32_t push_slot = 0;
	uint32_t arg_slot = 0;
	std::vector<BlobBinding> bindings;
};

// Every kernel compiled from one GLSL source, in one file. Carries a hash of its own payload: a blob
// that has been truncated or edited must announce that, not hand a device half a pipeline.
struct KernelBlob {
	std::vector<BlobKernel> kernels;

	static bool write(const std::string &path, const KernelBlob &blob, std::string &err);
	static bool read(const std::string &path, KernelBlob &blob, std::string &err);
};

} // namespace la
