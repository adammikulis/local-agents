#include "helpers/LocalAgentsFractureDebrisEmitter.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector3.hpp>

using namespace godot;

namespace {

constexpr const char *kLauncherNodeName = "FpsLauncherController";
constexpr int64_t kMaxPiecesPerMutation = 24;

int64_t as_i64(const Variant &value, int64_t fallback = 0) {
    if (value.get_type() == Variant::INT) {
        return static_cast<int64_t>(value);
    }
    if (value.get_type() == Variant::FLOAT) {
        return static_cast<int64_t>(static_cast<double>(value));
    }
    return fallback;
}

double as_f64(const Variant &value, double fallback = 0.0) {
    if (value.get_type() == Variant::FLOAT) {
        const double out = static_cast<double>(value);
        return std::isfinite(out) ? out : fallback;
    }
    if (value.get_type() == Variant::INT) {
        return static_cast<double>(static_cast<int64_t>(value));
    }
    return fallback;
}

bool as_bool(const Variant &value, bool fallback = false) {
    if (value.get_type() == Variant::BOOL) {
        return static_cast<bool>(value);
    }
    if (value.get_type() == Variant::INT) {
        return static_cast<int64_t>(value) != 0;
    }
    return fallback;
}

Array as_array(const Variant &value) {
    if (value.get_type() == Variant::ARRAY) {
        return static_cast<Array>(value);
    }
    return Array();
}

Vector3 as_vec3(const Variant &value, const Vector3 &fallback = Vector3()) {
    if (value.get_type() == Variant::VECTOR3) {
        return static_cast<Vector3>(value);
    }
    if (value.get_type() != Variant::DICTIONARY) {
        return fallback;
    }
    const Dictionary dict = value;
    return Vector3(
        static_cast<float>(as_f64(dict.get("x", fallback.x), fallback.x)),
        static_cast<float>(as_f64(dict.get("y", fallback.y), fallback.y)),
        static_cast<float>(as_f64(dict.get("z", fallback.z), fallback.z)));
}

String as_material_tag(const Dictionary &source, const String &fallback) {
    static const char *kMaterialKeys[] = {
        "destroyed_voxel_material_tag",
        "projectile_material_tag",
        "material_tag",
        "material_profile_key",
    };
    for (const char *key : kMaterialKeys) {
        const String tag = String(source.get(StringName(key), String())).strip_edges();
        if (!tag.is_empty()) {
            return tag;
        }
    }
    return fallback;
}

Array normalize_spawn_entries(const Array &spawn_entries, const String &default_material_tag) {
    Array out;
    const int64_t max_entries = std::clamp<int64_t>(spawn_entries.size(), 0, kMaxPiecesPerMutation);
    for (int64_t i = 0; i < max_entries; i += 1) {
        if (spawn_entries[i].get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary row = spawn_entries[i];
        Dictionary normalized;
        normalized["position"] = as_vec3(row.get("position", row), as_vec3(row, Vector3()));
        normalized["impulse_direction"] = as_vec3(row.get("impulse_direction", Vector3(0.0f, 1.0f, 0.0f)), Vector3(0.0f, 1.0f, 0.0f));
        normalized["impulse_size"] = std::max(0.0, as_f64(row.get("impulse_size", 0.0), 0.0));
        normalized["projectile_material_tag"] = as_material_tag(row, default_material_tag);
        normalized["projectile_hardness_tag"] = String(row.get("projectile_hardness_tag", String("hard")));
        normalized["projectile_radius"] = std::max(0.0, as_f64(row.get("projectile_radius", 0.07), 0.07));
        normalized["body_mass"] = std::max(0.01, as_f64(row.get("body_mass", 0.2), 0.2));
        normalized["projectile_ttl"] = std::max(0.1, as_f64(row.get("projectile_ttl", 1.2), 1.2));
        out.append(normalized);
    }
    return out;
}

Object *resolve_launcher(Object *simulation_controller) {
    if (simulation_controller == nullptr) {
        return nullptr;
    }
    if (simulation_controller->has_method(StringName("spawn_fracture_chunk_projectiles"))) {
        return simulation_controller;
    }
    Node *simulation_node = Object::cast_to<Node>(simulation_controller);
    if (simulation_node == nullptr || !simulation_node->is_inside_tree()) {
        return nullptr;
    }
    Node *launcher_node = simulation_node->get_node_or_null(NodePath(String(kLauncherNodeName)));
    if (launcher_node == nullptr || !launcher_node->has_method(StringName("spawn_fracture_chunk_projectiles"))) {
        return nullptr;
    }
    return launcher_node;
}

String resolve_default_material_tag(const Dictionary &stage_payload) {
    return as_material_tag(stage_payload, String("dense_voxel"));
}

} // namespace

int64_t LocalAgentsFractureDebrisEmitter::emit_for_mutation(Object *simulation_controller, int64_t tick, const Dictionary &stage_payload) const {
    if (simulation_controller == nullptr) {
        return 0;
    }
    const String default_material_tag = resolve_default_material_tag(stage_payload);
    Array spawn_entries = normalize_spawn_entries(as_array(stage_payload.get("spawn_entries", Array())), default_material_tag);
    bool spawn_entries_required = as_bool(stage_payload.get("spawn_entries_required", false), false);
    if (spawn_entries.is_empty()) {
        const Variant mutator_payload_variant = simulation_controller->get(StringName("_native_mutator_spawn_payload"));
        if (mutator_payload_variant.get_type() == Variant::DICTIONARY) {
            const Dictionary mutator_payload = static_cast<Dictionary>(mutator_payload_variant);
            const int64_t mutator_tick = as_i64(mutator_payload.get("tick", -1), -1);
            if (mutator_tick == tick) {
                spawn_entries = normalize_spawn_entries(as_array(mutator_payload.get("spawn_entries", Array())), default_material_tag);
                spawn_entries_required = spawn_entries_required || as_bool(mutator_payload.get("spawn_entries_required", false), false);
            }
        }
    }
    const bool has_spawn_entries = !spawn_entries.is_empty();
    if (!has_spawn_entries && spawn_entries_required) {
        UtilityFunctions::print(String("NATIVE_REQUIRED: spawn_entries_required_missing"));
        return 0;
    }
    if (!has_spawn_entries) {
        return 0;
    }

    Object *launcher = resolve_launcher(simulation_controller);
    if (launcher == nullptr) {
        UtilityFunctions::print(String("NATIVE_REQUIRED: fracture_chunk_projectile_launcher_unavailable"));
        return 0;
    }

    const Variant emitted_variant = launcher->call(
        StringName("spawn_fracture_chunk_projectiles"),
        spawn_entries,
        tick,
        default_material_tag
    );
    const int64_t emitted_count = std::max<int64_t>(0, as_i64(emitted_variant, 0));
    UtilityFunctions::print(String("NATIVE_FRACTURE_CHUNK_PROJECTILES_SPAWNED count=") + String::num_int64(emitted_count));
    return emitted_count;
}
