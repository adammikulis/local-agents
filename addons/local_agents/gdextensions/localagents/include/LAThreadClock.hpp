#ifndef LOCAL_AGENTS_LA_THREAD_CLOCK_HPP
#define LOCAL_AGENTS_LA_THREAD_CLOCK_HPP

#include <godot_cpp/classes/ref_counted.hpp>

namespace godot {

// CPU time the CALLING thread has run, in microseconds; time the OS gave other threads is not in it.
class LAThreadClock : public RefCounted {
	GDCLASS(LAThreadClock, RefCounted);

public:
	static int64_t cpu_usec();

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_THREAD_CLOCK_HPP
