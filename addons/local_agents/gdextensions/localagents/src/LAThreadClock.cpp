#include "LAThreadClock.hpp"

#include <godot_cpp/core/class_db.hpp>

#include <time.h>

using namespace godot;

int64_t LAThreadClock::cpu_usec() {
	struct timespec ts;
	if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) {
		return -1;
	}
	return (int64_t)ts.tv_sec * 1000000 + (int64_t)(ts.tv_nsec / 1000);
}

void LAThreadClock::_bind_methods() {
	ClassDB::bind_static_method("LAThreadClock", D_METHOD("cpu_usec"), &LAThreadClock::cpu_usec);
}
