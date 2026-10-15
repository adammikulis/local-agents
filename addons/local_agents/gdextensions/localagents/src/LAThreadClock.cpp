#include "LAThreadClock.hpp"

#include <godot_cpp/core/class_db.hpp>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <time.h>
#endif

using namespace godot;

int64_t LAThreadClock::cpu_usec() {
#ifdef _WIN32
	FILETIME creation, exit, kernel, user;
	if (!GetThreadTimes(GetCurrentThread(), &creation, &exit, &kernel, &user)) {
		return -1;
	}
	const uint64_t kernel_ticks = (uint64_t(kernel.dwHighDateTime) << 32) | kernel.dwLowDateTime;
	const uint64_t user_ticks = (uint64_t(user.dwHighDateTime) << 32) | user.dwLowDateTime;
	return int64_t((kernel_ticks + user_ticks) / 10);
#else
	struct timespec ts;
	if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) {
		return -1;
	}
	return (int64_t)ts.tv_sec * 1000000 + (int64_t)(ts.tv_nsec / 1000);
#endif
}

void LAThreadClock::_bind_methods() {
	ClassDB::bind_static_method("LAThreadClock", D_METHOD("cpu_usec"), &LAThreadClock::cpu_usec);
}
