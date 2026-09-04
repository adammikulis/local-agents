#pragma once

#include <string>

namespace la {
class Device;
}

namespace lasim {

// 0 clean · 1 a failure the device or the kernels own · 2 the arm could not run.
int selftest_device(la::Device &dev, const std::string &blob);
int selftest_kernels(la::Device &dev, const std::string &blob);

} // namespace lasim
