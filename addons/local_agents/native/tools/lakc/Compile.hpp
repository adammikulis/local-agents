#pragma once

#include "la/KernelBlob.hpp"

#include <string>

namespace lakc {

void init();
void finalize();

// One .glsl under `dir` to one baked kernel. Returns false with `err` naming the file and the line on a
// preprocessor, compile or translation failure. There is no partial success: a kernel that does not
// compile is a build failure, never a pipeline the device discovers is null at run time.
bool compile_kernel(const std::string &dir, const std::string &file, la::BlobKernel &out,
		std::string &err);

} // namespace lakc
