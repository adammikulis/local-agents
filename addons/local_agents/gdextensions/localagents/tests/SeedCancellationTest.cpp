#include "LAParallel.hpp"
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <stdexcept>

using namespace godot;

int main() {
	std::atomic<int> completed{0}, live{0};
	la_parallel_for(256, [&](int) { completed.fetch_add(1); });
	if (completed != 256) { return 1; }
	std::atomic<bool> cancel{false}, entered{false}, escaped{false};
	std::mutex mutex;
	std::condition_variable changed;
	bool caught = false;
	std::thread controller([&] {
		std::unique_lock<std::mutex> lock(mutex);
		changed.wait_for(lock, std::chrono::seconds(1), [&] { return entered.load(); });
		cancel.store(true);
	});
	{
		LASeedCancellation scope(&cancel);
		try {
			la_parallel_for(256, [&](int) {
				struct Guard {
					std::atomic<int> &live;
					explicit Guard(std::atomic<int> &value) : live(value) { live.fetch_add(1); }
					~Guard() { live.fetch_sub(1); }
				} guard(live);
				if (LASeedCancellation::token() != &cancel) { throw std::runtime_error("lost cancellation"); }
				{
					std::lock_guard<std::mutex> lock(mutex);
					entered.store(true);
				}
				changed.notify_one();
				while (!cancel.load()) { std::this_thread::yield(); }
				LASeedCancellation::check();
				escaped.store(true);
			});
		} catch (const LASeedCancellation::Cancelled &) {
			caught = true;
		} catch (...) {
		}
	}
	controller.join();
	if (!caught || !entered || escaped || live != 0 || LASeedCancellation::token()) { return 1; }
	bool error_propagated = false;
	try {
		la_parallel_for(256, [&](int) { throw std::runtime_error("worker failure"); });
	} catch (const std::runtime_error &) {
		error_propagated = true;
	}
	return error_propagated ? 0 : 1;
}
