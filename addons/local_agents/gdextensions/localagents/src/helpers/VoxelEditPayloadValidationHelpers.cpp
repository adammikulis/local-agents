#include "helpers/VoxelEditPayloadValidationHelpers.hpp"

#include "FailureEmissionDeterministicNoise.hpp"
#include "helpers/VoxelEditParsingHelpers.hpp"

#include <algorithm>
#include <cmath>

using namespace godot;

namespace local_agents::simulation::helpers {
namespace {

String resolve_projectile_material_tag(const Dictionary &op_payload) {
    static const char *kTagKeys[] = {
        "destroyed_voxel_material_tag",
        "projectile_material_tag",
        "material_tag",
        "material_profile_key",
    };
    for (const char *key : kTagKeys) {
        const String raw = String(op_payload.get(StringName(key), String())).strip_edges();
        if (!raw.is_empty()) {
            return raw;
        }
    }
    return String("dense_voxel");
}

} // namespace

bool is_valid_operation(const String &operation) {
    return operation == String("set") || operation == String("add") || operation == String("max") ||
           operation == String("min") || operation == String("fracture") || operation == String("cleave");
}

bool parse_stage_domain(const String &stage_domain, VoxelEditDomain &domain_out) {
    const String normalized = stage_domain.to_lower();
    if (normalized == String("environment")) {
        domain_out = VoxelEditDomain::Environment;
        return true;
    }
    if (normalized == String("voxel")) {
        domain_out = VoxelEditDomain::Voxel;
        return true;
    }
    return false;
}

bool parse_op_payload(
    const String &stage_domain,
    const StringName &stage_name,
    const Dictionary &op_payload,
    VoxelEditOp &op_out,
    String &error_code_out
) {
    if (String(stage_name).is_empty()) {
        error_code_out = String("invalid_stage_name");
        return false;
    }

    VoxelEditDomain parsed_domain = VoxelEditDomain::Voxel;
    if (!parse_stage_domain(stage_domain, parsed_domain)) {
        error_code_out = String("invalid_stage_domain");
        return false;
    }

    if (!op_payload.has("x") || !op_payload.has("y") || !op_payload.has("z")) {
        error_code_out = String("missing_voxel_coordinate");
        return false;
    }

    int32_t x = 0;
    int32_t y = 0;
    int32_t z = 0;
    if (!parse_int32_variant(op_payload["x"], x) || !parse_int32_variant(op_payload["y"], y) ||
        !parse_int32_variant(op_payload["z"], z)) {
        error_code_out = String("invalid_voxel_coordinate");
        return false;
    }

    String operation = String(op_payload.get("operation", String("set"))).to_lower();
    if (!is_valid_operation(operation)) {
        error_code_out = String("invalid_operation");
        return false;
    }

    double value = 1.0;
    if (op_payload.has("value") && !parse_double_variant(op_payload["value"], value)) {
        error_code_out = String("invalid_value");
        return false;
    }
    if (!std::isfinite(value) || value < 0.0) {
        error_code_out = String("invalid_value");
        return false;
    }

    String shape = String("sphere");
    if (operation == String("fracture") || operation == String("cleave")) {
        shape = String(op_payload.get("shape", String("sphere")));
        if (operation == String("fracture") && !parse_fracture_shape(shape, shape)) {
            error_code_out = String("invalid_fracture_shape");
            return false;
        }

        double radius = 1.0;
        if (op_payload.has("radius") && !parse_double_variant(op_payload["radius"], radius)) {
            error_code_out = String("invalid_fracture_radius");
            return false;
        }
        if (radius <= 0.0 || !std::isfinite(radius)) {
            error_code_out = String("invalid_fracture_radius");
            return false;
        }
        op_out.radius = radius;
        op_out.shape = shape;
        DeterministicNoiseProfile noise_profile;
        read_deterministic_noise_fields(op_payload, noise_profile);
        op_out.noise_seed = noise_profile.seed;
        op_out.noise_amplitude = noise_profile.amplitude;
        op_out.noise_frequency = noise_profile.frequency;
        op_out.noise_octaves = noise_profile.octaves;
        op_out.noise_lacunarity = noise_profile.lacunarity;
        op_out.noise_gain = noise_profile.gain;
        op_out.noise_mode = noise_profile.mode;

        if (operation == String("cleave")) {
            if (!op_payload.has("plane_normal")) {
                error_code_out = String("missing_cleave_plane_normal");
                return false;
            }
            double plane_x = 0.0;
            double plane_y = 0.0;
            double plane_z = 0.0;
            if (!parse_vector3_variant(op_payload.get("plane_normal", Dictionary()), plane_x, plane_y, plane_z)) {
                error_code_out = String("invalid_cleave_plane_normal");
                return false;
            }
            const double plane_length = std::sqrt(plane_x * plane_x + plane_y * plane_y + plane_z * plane_z);
            if (!std::isfinite(plane_length) || plane_length <= 1.0e-6) {
                error_code_out = String("invalid_cleave_plane_normal");
                return false;
            }
            const double normalized_x = plane_x / plane_length;
            const double normalized_y = plane_y / plane_length;
            const double normalized_z = plane_z / plane_length;

            double plane_offset = (normalized_x * static_cast<double>(x))
                + (normalized_y * static_cast<double>(y))
                + (normalized_z * static_cast<double>(z));
            if (op_payload.has("plane_offset") && !parse_double_variant(op_payload["plane_offset"], plane_offset)) {
                error_code_out = String("invalid_cleave_plane_offset");
                return false;
            }
            if (!std::isfinite(plane_offset)) {
                error_code_out = String("invalid_cleave_plane_offset");
                return false;
            }
            op_out.cleave_normal_x = normalized_x;
            op_out.cleave_normal_y = normalized_y;
            op_out.cleave_normal_z = normalized_z;
            op_out.cleave_plane_offset = plane_offset;
        }
    }

    op_out.domain = parsed_domain;
    op_out.stage_name = stage_name;
    op_out.voxel.x = x;
    op_out.voxel.y = y;
    op_out.voxel.z = z;
    op_out.operation = operation;
    op_out.value = value;
    op_out.projectile_material_tag = resolve_projectile_material_tag(op_payload);
    if (op_payload.has("durability_hits")) {
        double durability_hits = 0.0;
        if (parse_double_variant(op_payload.get("durability_hits", 0.0), durability_hits) && std::isfinite(durability_hits)) {
            op_out.durability_hits = std::max(0.0, durability_hits);
        }
    }
    if (op_payload.has("fracture_chip_progress_prior")) {
        double progress_prior = -1.0;
        if (parse_double_variant(op_payload.get("fracture_chip_progress_prior", -1.0), progress_prior) && std::isfinite(progress_prior)) {
            op_out.fracture_chip_progress_prior = progress_prior;
        }
    }
    if (op_payload.has("fracture_chip_progress_next")) {
        double progress_next = -1.0;
        if (parse_double_variant(op_payload.get("fracture_chip_progress_next", -1.0), progress_next) && std::isfinite(progress_next)) {
            op_out.fracture_chip_progress_next = progress_next;
        }
    }
    if (op_payload.has("fracture_chip_damage_last")) {
        double damage_last = 0.0;
        if (parse_double_variant(op_payload.get("fracture_chip_damage_last", 0.0), damage_last) && std::isfinite(damage_last)) {
            op_out.fracture_chip_damage_last = std::max(0.0, damage_last);
        }
    }
    if (op_payload.has("fracture_chip_hits")) {
        int32_t chip_hits = -1;
        if (parse_int32_variant(op_payload.get("fracture_chip_hits", -1), chip_hits)) {
            op_out.fracture_chip_hits = chip_hits;
        }
    }
    if (op_payload.has("fracture_chip_state")) {
        const String state = String(op_payload.get("fracture_chip_state", String())).strip_edges();
        if (!state.is_empty()) {
            op_out.fracture_chip_state = state;
        }
    }
    if (op_payload.has("chip_progress_spawn_count")) {
        int64_t spawn_count = static_cast<int64_t>(op_payload.get("chip_progress_spawn_count", static_cast<int64_t>(0)));
        op_out.chip_progress_spawn_count = std::max<int64_t>(0, spawn_count);
    }
    return true;
}

} // namespace local_agents::simulation::helpers
