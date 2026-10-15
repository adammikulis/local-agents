#pragma once

#include <atomic>

namespace godot {

class LASeedCancellation {
	inline static thread_local const std::atomic<bool> *active = nullptr;
	const std::atomic<bool> *previous;

public:
	struct Cancelled {};
	explicit LASeedCancellation(const std::atomic<bool> *requested) : previous(active) { active = requested; }
	static const std::atomic<bool> *token() { return active; }
	~LASeedCancellation() { active = previous; }
	LASeedCancellation(const LASeedCancellation &) = delete;
	LASeedCancellation &operator=(const LASeedCancellation &) = delete;
	static void check() {
		if (active && active->load(std::memory_order_relaxed)) { throw Cancelled{}; }
	}
};

}
