#include "Selftest.hpp"
#include "la/Device.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <libgen.h>
#include <string>
#include <vector>

namespace {

const char *kUsage =
		"Usage: lasim [--backend metal|vulkan] [--device N] [--kernels FILE]\n"
		"             [--selftest-device | --selftest-kernels]\n";

// The blob sits beside the binary, which is where the build writes it.
std::string blob_beside(const char *argv0) {
	std::vector<char> tmp(std::strlen(argv0) + 1);
	std::memcpy(tmp.data(), argv0, tmp.size());
	return std::string(dirname(tmp.data())) + "/kernels.blob";
}

} // namespace

int main(int argc, char **argv) {
	la::Backend backend = la::Backend::Metal;
	int index = 0;
	std::string blob;
	bool want_device = false;
	bool want_kernels = false;

	for (int i = 1; i < argc; ++i) {
		const std::string a = argv[i];
		if (a == "--backend" && i + 1 < argc) {
			const std::string b = argv[++i];
			if (b == "metal") {
				backend = la::Backend::Metal;
			} else if (b == "vulkan") {
				backend = la::Backend::Vulkan;
			} else {
				std::fprintf(stderr, "lasim: unknown backend '%s'\n", b.c_str());
				return 2;
			}
		} else if (a == "--device" && i + 1 < argc) {
			index = std::atoi(argv[++i]);
		} else if (a == "--kernels" && i + 1 < argc) {
			blob = argv[++i];
		} else if (a == "--selftest-device") {
			want_device = true;
		} else if (a == "--selftest-kernels") {
			want_kernels = true;
		} else if (a == "-h" || a == "--help") {
			std::fputs(kUsage, stdout);
			return 0;
		} else {
			std::fprintf(stderr, "lasim: unknown argument '%s'\n%s", a.c_str(), kUsage);
			return 2;
		}
	}
	if (!want_device && !want_kernels) {
		std::fputs(kUsage, stderr);
		return 2;
	}
	if (blob.empty()) { blob = blob_beside(argv[0]); }

	std::string err;
	std::unique_ptr<la::Device> dev = la::Device::create(backend, index, err);
	if (dev == nullptr) {
		std::fprintf(stderr, "lasim: %s\n", err.c_str());
		std::printf("LA_RUN_COMPLETE={\"code\":2}\n");
		return 2;
	}

	int code = 0;
	if (want_device) { code = lasim::selftest_device(*dev, blob); }
	if (code == 0 && want_kernels) { code = lasim::selftest_kernels(*dev, blob); }
	std::printf("LA_RUN_COMPLETE={\"code\":%d}\n", code);
	return code;
}
