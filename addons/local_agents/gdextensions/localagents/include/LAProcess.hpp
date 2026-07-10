#ifndef LOCAL_AGENTS_PROCESS_HPP
#define LOCAL_AGENTS_PROCESS_HPP

#include <godot_cpp/classes/ref_counted.hpp>

namespace godot {

// LAProcess — a tiny process-control helper exposing ONE thing GDScript cannot do
// on its own: a hard, clean process exit with an explicit exit code.
//
// Why it exists: on macOS/Metal the normal SceneTree.quit() path runs through
// `-[NSApplication terminate:]`, which posts NSApplicationWillTerminate. MoltenVK's
// termination observer then locks an already-destroyed recursive_mutex and aborts
// (SIGABRT / rc=134) AFTER our clean shutdown has already finished. `exit_now` skips
// that teardown-order landmine entirely: it flushes stdio (so SIM_REPORT and any
// buffered output reach the pipe) and calls std::_Exit, which terminates immediately
// with the given code, running no C++ static destructors and firing no AppKit
// termination notification. The kernel reclaims all memory/GPU resources on exit.
//
// Use ONLY on real quit, after the normal shutdown path has flushed saves/config.
class LAProcess : public RefCounted {
    GDCLASS(LAProcess, RefCounted);

public:
    static void exit_now(int code);

protected:
    static void _bind_methods();
};

}

#endif
