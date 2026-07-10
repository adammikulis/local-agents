#include "LAProcess.hpp"

#include <godot_cpp/core/class_db.hpp>

#include <cstdio>
#include <cstdlib>

using namespace godot;

void LAProcess::_bind_methods() {
    ClassDB::bind_static_method("LAProcess", D_METHOD("exit_now", "code"), &LAProcess::exit_now);
}

void LAProcess::exit_now(int code) {
    // Flush first so already-printed output (e.g. SIM_REPORT) reaches the pipe —
    // _Exit does NOT flush stdio. Then terminate immediately: no static destructors,
    // no atexit handlers, no AppKit NSApplication-terminate notification (the path
    // that triggers MoltenVK's recursive_mutex abort at process exit on macOS/Metal).
    std::fflush(stdout);
    std::fflush(stderr);
    std::_Exit(code);
}
