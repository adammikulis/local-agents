#include "field/ViewPublication.hpp"
#include <atomic>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <thread>
#include <unistd.h>

namespace fs = std::filesystem;

int main() {
	const fs::path root = fs::temp_directory_path() / ("la_view_test_" + std::to_string(getpid()));
	if (!fs::create_directory(root)) { return 2; }
	std::string err, path;
	int code = 0;
	{
		lasim::ViewPublication publication;
		if (!publication.initialize(root.string(), 41, err)) { return 2; }
		lasim::ViewDraft view;
		view.generation = 3;
		view.sequence = 1;
		view.bytes.assign(16 * 1024 * 1024, 0xa7);
		std::atomic<bool> stop{false}, partial{false}, started{false};
		const fs::path directory = root / "session-41";
		std::thread observer([&] {
			started.store(true);
			while (!stop.load()) {
				std::error_code ec;
				for (const auto &entry : fs::directory_iterator(directory, ec)) {
					if (entry.path().extension() != ".lavw") { continue; }
					const auto size = fs::file_size(entry.path(), ec);
					if (!ec && size != view.bytes.size()) { partial.store(true); }
				}
			}
		});
		while (!started.load()) { std::this_thread::yield(); }
		const fs::path control = directory / "control.lavw";
		std::ofstream(control).put('x');
		const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
		while (!partial.load() && std::chrono::steady_clock::now() < deadline) { std::this_thread::yield(); }
		if (!partial.load()) { code = 1; }
		fs::remove(control);
		stop.store(true);
		observer.join();
		partial.store(false);
		stop.store(false);
		std::thread actual([&] {
			while (!stop.load()) {
				std::error_code ec;
				for (const auto &entry : fs::directory_iterator(directory, ec)) {
					if (entry.path().extension() != ".lavw") { continue; }
					const auto size = fs::file_size(entry.path(), ec);
					if (!ec && size != view.bytes.size()) { partial.store(true); }
				}
			}
		});
		for (int i = 0; i < 8; ++i) {
			view.sequence++;
			if (!publication.publish(view, path, err)) { code = 1; break; }
			std::ifstream input(path, std::ios::binary);
			const std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(input)), {});
			if (bytes != view.bytes || !publication.busy()) { code = 1; }
			std::string refused;
			if (publication.publish(view, refused, err) || publication.acknowledge(view.sequence + 1, err)
					|| !fs::exists(path)) { code = 1; }
			if (!publication.acknowledge(view.sequence, err) || publication.busy() || fs::exists(path)) { code = 1; }
		}
		stop.store(true);
		actual.join();
		if (partial.load()) { code = 1; }
		view.sequence++;
		if (!publication.publish(view, path, err)) { code = 1; }
	}
	if (!fs::is_empty(root)) { code = 1; }
	fs::remove(root);
	if (code != 0) { std::fprintf(stderr, "publication visibility, ownership or cleanup failed\n"); }
	return code;
}
