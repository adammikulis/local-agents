#ifndef LOCAL_AGENTS_FRACTURE_DEBRIS_EMITTER_HPP
#define LOCAL_AGENTS_FRACTURE_DEBRIS_EMITTER_HPP

#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

class Object;

class LocalAgentsFractureDebrisEmitter {
public:
    int64_t emit_for_mutation(Object *simulation_controller, int64_t tick, const Dictionary &stage_payload) const;
};

} // namespace godot

#endif // LOCAL_AGENTS_FRACTURE_DEBRIS_EMITTER_HPP
