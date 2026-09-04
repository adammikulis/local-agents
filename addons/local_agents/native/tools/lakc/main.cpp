#include "Compile.hpp"
#include "la/KernelBlob.hpp"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <string>
#include <vector>

namespace {

const char *kUsage =
		"Usage: lakc --kernels DIR [--out FILE | --check] [--dump NAME]\n"
		"  --check   compile every kernel and exit 1 on the first error, naming file and line\n"
		"  --out     write the compiled kernels to a blob\n"
		"  --dump    print one kernel's MSL to stdout\n";

std::vector<std::string> kernel_files(const std::string &dir) {
	std::vector<std::string> out;
	DIR *d = opendir(dir.c_str());
	if (d == nullptr) { return out; }
	while (dirent *e = readdir(d)) {
		const std::string name = e->d_name;
		if (name.size() > 5 && name.compare(name.size() - 5, 5, ".glsl") == 0) {
			out.push_back(name);
		}
	}
	closedir(d);
	std::sort(out.begin(), out.end());
	return out;
}

} // namespace

int main(int argc, char **argv) {
	std::string dir;
	std::string out_path;
	std::string dump;
	bool check = false;
	for (int i = 1; i < argc; ++i) {
		const std::string a = argv[i];
		if (a == "--kernels" && i + 1 < argc) {
			dir = argv[++i];
		} else if (a == "--out" && i + 1 < argc) {
			out_path = argv[++i];
		} else if (a == "--dump" && i + 1 < argc) {
			dump = argv[++i];
		} else if (a == "--check") {
			check = true;
		} else if (a == "-h" || a == "--help") {
			std::fputs(kUsage, stdout);
			return 0;
		} else {
			std::fprintf(stderr, "lakc: unknown argument '%s'\n%s", a.c_str(), kUsage);
			return 2;
		}
	}
	if (dir.empty()) {
		std::fputs(kUsage, stderr);
		return 2;
	}
	const std::vector<std::string> files = kernel_files(dir);
	if (files.empty()) {
		std::fprintf(stderr, "lakc: no .glsl kernels under %s\n", dir.c_str());
		return 2;
	}

	lakc::init();
	la::KernelBlob blob;
	int failed = 0;
	for (const std::string &f : files) {
		la::BlobKernel k;
		std::string err;
		const bool ok = lakc::compile_kernel(dir, f, k, err);
		if (!dump.empty() && k.name == dump) { std::fputs(k.msl.c_str(), stdout); }
		if (!ok) {
			std::fprintf(stderr, "lakc: %s FAILED\n%s\n", f.c_str(), err.c_str());
			++failed;
			continue;
		}
		if (check) {
			std::printf("LAKC_KERNEL={\"name\":\"%s\",\"bindings\":%zu,\"push\":%u,\"local\":%u}\n",
					k.name.c_str(), k.bindings.size(), k.push_size, k.local[0]);
		}
		if (!dump.empty() && k.name == dump) { std::fputs(k.msl.c_str(), stdout); }
		blob.kernels.push_back(std::move(k));
	}
	lakc::finalize();

	if (failed > 0) {
		std::fprintf(stderr, "lakc: %d of %zu kernels did not compile.\n", failed, files.size());
		return 1;
	}
	if (!out_path.empty()) {
		std::string err;
		if (!la::KernelBlob::write(out_path, blob, err)) {
			std::fprintf(stderr, "lakc: %s\n", err.c_str());
			return 2;
		}
	}
	std::printf("LAKC_OK={\"kernels\":%zu}\n", blob.kernels.size());
	return 0;
}
