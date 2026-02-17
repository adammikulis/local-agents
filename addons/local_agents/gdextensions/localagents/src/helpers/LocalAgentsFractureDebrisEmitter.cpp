#include "helpers/LocalAgentsFractureDebrisEmitter.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>

#include <godot_cpp/classes/box_mesh.hpp>
#include <godot_cpp/classes/box_shape3d.hpp>
#include <godot_cpp/classes/collision_shape3d.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/rigid_body3d.hpp>
#include <godot_cpp/core/memory.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector3.hpp>

using namespace godot;

namespace {

constexpr const char *kDebrisRootName = "NativeFractureDebrisRoot";
constexpr int64_t kMaxPiecesPerMutation = 24;
constexpr int64_t kMaxActiveDebris = 192;
constexpr int64_t kDefaultChunkSpan = 12;
constexpr double kPieceSizeMin = 0.12;
constexpr double kPieceSizeMax = 0.32;
constexpr double kImpulseMin = 1.8;
constexpr double kImpulseMax = 5.2;
constexpr double kUpwardBias = 0.45;

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

int64_t as_i64(const Variant &value, int64_t fallback = 0) {
    if (value.get_type() == Variant::INT) {
        return static_cast<int64_t>(value);
    }
    if (value.get_type() == Variant::FLOAT) {
        return static_cast<int64_t>(as_f64(value, static_cast<double>(fallback)));
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

Dictionary as_dictionary(const Variant &value) {
    if (value.get_type() == Variant::DICTIONARY) {
        return static_cast<Dictionary>(value);
    }
    return Dictionary();
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
        static_cast<float>(as_f64(dict.get("x", 0.0), fallback.x)),
        static_cast<float>(as_f64(dict.get("y", 0.0), fallback.y)),
        static_cast<float>(as_f64(dict.get("z", 0.0), fallback.z)));
}

uint64_t mix_u64(uint64_t x) {
    x += 0x9e3779b97f4a7c15ULL;
    x = (x ^ (x >> 30U)) * 0xbf58476d1ce4e5b9ULL;
    x = (x ^ (x >> 27U)) * 0x94d049bb133111ebULL;
    return x ^ (x >> 31U);
}

double seeded_unit(uint64_t base_seed, int64_t index, uint64_t stream) {
    const uint64_t mixed = mix_u64(base_seed ^ (stream + 0x9e3779b97f4a7c15ULL * static_cast<uint64_t>(index + 1)));
    return static_cast<double>(mixed & 0xFFFFFFU) / 16777215.0;
}

bool resolve_region_bounds(const Dictionary &stage_payload, Vector3 &min_point, Vector3 &max_point) {
    const Dictionary changed_region = as_dictionary(stage_payload.get("changed_region", Dictionary()));
    if (changed_region.is_empty() || !as_bool(changed_region.get("valid", false), false)) {
        return false;
    }
    const Dictionary min_dict = as_dictionary(changed_region.get("min", Dictionary()));
    const Dictionary max_dict = as_dictionary(changed_region.get("max", Dictionary()));
    if (min_dict.is_empty() || max_dict.is_empty()) {
        return false;
    }
    const Vector3 raw_min = as_vec3(min_dict, Vector3());
    const Vector3 raw_max = as_vec3(max_dict, Vector3());
    min_point = Vector3(
        std::min(raw_min.x, raw_max.x),
        std::min(raw_min.y, raw_max.y),
        std::min(raw_min.z, raw_max.z));
    max_point = Vector3(
        std::max(raw_min.x, raw_max.x),
        std::max(raw_min.y, raw_max.y),
        std::max(raw_min.z, raw_max.z));
    return true;
}

Array normalize_chunk_rows(const Array &changed_chunks) {
    Array out;
    for (int64_t i = 0; i < changed_chunks.size(); i += 1) {
        if (changed_chunks[i].get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary row = changed_chunks[i];
        Dictionary normalized;
        normalized["x"] = as_i64(row.get("x", 0), 0);
        normalized["y"] = as_i64(row.get("y", 0), 0);
        normalized["z"] = as_i64(row.get("z", row.get("y", 0)), 0);
        out.append(normalized);
    }
    return out;
}

Vector3 chunk_center(const Dictionary &chunk, int64_t chunk_span) {
    const double span = static_cast<double>(std::max<int64_t>(1, chunk_span));
    return Vector3(
        static_cast<float>(as_i64(chunk.get("x", 0), 0) * span + span * 0.5),
        static_cast<float>(as_i64(chunk.get("y", 0), 0) * span + span * 0.5),
        static_cast<float>(as_i64(chunk.get("z", 0), 0) * span + span * 0.5));
}

Node3D *resolve_debris_root(Object *simulation_controller) {
    Node *simulation_node = Object::cast_to<Node>(simulation_controller);
    if (simulation_node == nullptr || !simulation_node->is_inside_tree()) {
        return nullptr;
    }
    Node *existing = simulation_node->get_node_or_null(NodePath(String(kDebrisRootName)));
    Node3D *root = Object::cast_to<Node3D>(existing);
    if (root != nullptr) {
        return root;
    }
    root = memnew(Node3D);
    root->set_name(StringName(kDebrisRootName));
    simulation_node->add_child(root);
    return root;
}

int64_t trim_active_debris(Node3D *root, int64_t max_active) {
    if (root == nullptr) {
        return 0;
    }
    while (root->get_child_count() > static_cast<int>(max_active)) {
        Node *stale = root->get_child(0);
        if (stale == nullptr) {
            break;
        }
        stale->queue_free();
    }
    return root->get_child_count();
}

Vector3 resolve_contact_origin(const Array &contact_rows) {
    for (int64_t i = 0; i < contact_rows.size(); i += 1) {
        if (contact_rows[i].get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary row = contact_rows[i];
        const Variant point_variant = row.get("contact_point", Variant());
        if (point_variant.get_type() == Variant::VECTOR3) {
            return static_cast<Vector3>(point_variant);
        }
    }
    return Vector3();
}

Vector3 resolve_impulse_direction(const Array &contact_rows, int64_t piece_index, const Vector3 &spawn_position, const Vector3 &fallback_center) {
    if (!contact_rows.is_empty()) {
        const int64_t row_index = piece_index % contact_rows.size();
        if (contact_rows[row_index].get_type() == Variant::DICTIONARY) {
            const Dictionary row = contact_rows[row_index];
            const Variant normal_variant = row.get("contact_normal", Variant());
            if (normal_variant.get_type() == Variant::VECTOR3) {
                const Vector3 normal = static_cast<Vector3>(normal_variant);
                if (normal.length_squared() > 0.0001f) {
                    return normal.normalized();
                }
            }
            const Variant point_variant = row.get("contact_point", Variant());
            if (point_variant.get_type() == Variant::VECTOR3) {
                Vector3 outward = spawn_position - static_cast<Vector3>(point_variant);
                if (outward.length_squared() > 0.0001f) {
                    return outward.normalized();
                }
            }
        }
    }
    Vector3 outward = spawn_position - fallback_center;
    outward.y += static_cast<float>(kUpwardBias);
    if (outward.length_squared() < 0.0001f) {
        outward = Vector3(0.0f, 1.0f, 0.0f);
    }
    return outward.normalized();
}

} // namespace

int64_t LocalAgentsFractureDebrisEmitter::emit_for_mutation(Object *simulation_controller, int64_t tick, const Dictionary &stage_payload) const {
    Vector3 region_min;
    Vector3 region_max;
    const bool has_region = resolve_region_bounds(stage_payload, region_min, region_max);
    const Array changed_chunks = normalize_chunk_rows(as_array(stage_payload.get("changed_chunks", Array())));
    const bool has_chunks = !changed_chunks.is_empty();
    if (!has_region && !has_chunks) {
        return 0;
    }

    Node3D *debris_root = resolve_debris_root(simulation_controller);
    if (debris_root == nullptr) {
        return 0;
    }

    const int64_t chunk_span = std::max<int64_t>(1, as_i64(stage_payload.get("block_rows_chunk_size", stage_payload.get("chunk_size", kDefaultChunkSpan)), kDefaultChunkSpan));
    const int64_t chunk_budget = has_chunks ? changed_chunks.size() * 3 : kMaxPiecesPerMutation;
    const int64_t planned_piece_count = std::clamp<int64_t>(std::max<int64_t>(1, chunk_budget), 1, kMaxPiecesPerMutation);

    int64_t active_count = trim_active_debris(debris_root, kMaxActiveDebris);
    const int64_t available_slots = std::max<int64_t>(0, kMaxActiveDebris - active_count);
    const int64_t spawn_count = std::min<int64_t>(planned_piece_count, available_slots);
    if (spawn_count <= 0) {
        UtilityFunctions::print(String("NATIVE_FRACTURE_DEBRIS_EMITTED count=0"));
        return 0;
    }

    const uint64_t seed = mix_u64(static_cast<uint64_t>(tick) ^ static_cast<uint64_t>(spawn_count * 37));
    const Array contact_rows = as_array(stage_payload.get("physics_contacts", Array()));
    const Vector3 contact_origin = resolve_contact_origin(contact_rows);
    const Vector3 fallback_center = has_region ? ((region_min + region_max) * 0.5f) : contact_origin;

    int64_t emitted_count = 0;
    for (int64_t i = 0; i < spawn_count; i += 1) {
        Vector3 spawn_position = fallback_center;
        if (has_region) {
            const float rx = static_cast<float>(seeded_unit(seed, i, 11));
            const float ry = static_cast<float>(seeded_unit(seed, i, 17));
            const float rz = static_cast<float>(seeded_unit(seed, i, 23));
            spawn_position = Vector3(
                region_min.x + (region_max.x - region_min.x + 1.0f) * rx,
                region_min.y + (region_max.y - region_min.y + 1.0f) * ry,
                region_min.z + (region_max.z - region_min.z + 1.0f) * rz);
        } else if (has_chunks) {
            const int64_t chunk_index = i % changed_chunks.size();
            const Dictionary chunk = changed_chunks[chunk_index];
            const Vector3 center = chunk_center(chunk, chunk_span);
            const float span = static_cast<float>(chunk_span);
            spawn_position = center + Vector3(
                (static_cast<float>(seeded_unit(seed, i, 31)) - 0.5f) * span * 0.35f,
                (static_cast<float>(seeded_unit(seed, i, 37))) * span * 0.20f,
                (static_cast<float>(seeded_unit(seed, i, 41)) - 0.5f) * span * 0.35f);
        }

        RigidBody3D *body = memnew(RigidBody3D);
        body->set_name(StringName(vformat("Debris_%d_%d", tick, i)));
        body->set_position(spawn_position);
        body->set_mass(0.08);
        body->set_linear_damp(0.1);
        body->set_angular_damp(0.1);

        const double piece_size = kPieceSizeMin + (kPieceSizeMax - kPieceSizeMin) * seeded_unit(seed, i, 47);
        Ref<BoxShape3D> box_shape;
        box_shape.instantiate();
        box_shape->set_size(Vector3(static_cast<float>(piece_size), static_cast<float>(piece_size), static_cast<float>(piece_size)));
        CollisionShape3D *collision_shape = memnew(CollisionShape3D);
        collision_shape->set_shape(box_shape);
        body->add_child(collision_shape);

        Ref<BoxMesh> box_mesh;
        box_mesh.instantiate();
        box_mesh->set_size(Vector3(static_cast<float>(piece_size), static_cast<float>(piece_size), static_cast<float>(piece_size)));
        MeshInstance3D *mesh_instance = memnew(MeshInstance3D);
        mesh_instance->set_mesh(box_mesh);
        body->add_child(mesh_instance);

        debris_root->add_child(body);
        const Vector3 impulse_direction = resolve_impulse_direction(contact_rows, i, spawn_position, fallback_center);
        const double impulse_size = kImpulseMin + (kImpulseMax - kImpulseMin) * seeded_unit(seed, i, 53);
        if (body->is_inside_tree()) {
            body->apply_central_impulse(impulse_direction * static_cast<float>(impulse_size));
        }
        emitted_count += 1;
    }

    UtilityFunctions::print(String("NATIVE_FRACTURE_DEBRIS_EMITTED count=") + String::num_int64(emitted_count));
    return emitted_count;
}
