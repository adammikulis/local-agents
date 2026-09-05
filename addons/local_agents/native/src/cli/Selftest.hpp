#pragma once

#include <cstdint>
#include <string>

namespace la {
class Device;
}

namespace lasim {

// A float32 sum of six face integrals carries this much of the cell's own weight and no more.
constexpr float kStackResidualBar = 1.0e-5f;

// 0 clean · 1 a failure the device or the kernels own · 2 the arm could not run.
int selftest_device(la::Device &dev, const std::string &blob);
int selftest_kernels(la::Device &dev, const std::string &blob);
// `only` names one property, or nullptr for every one the blob's kernels carry.
int property_tests(la::Device &dev, const std::string &blob, uint64_t seed, const char *only);

} // namespace lasim
