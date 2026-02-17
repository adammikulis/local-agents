#include "LocalAgentsWorldSimulationNativeUtils.hpp"

#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

using namespace godot;

namespace {
constexpr const char *kTestModeFpsFireDestroy = "fps_fire_destroy";
constexpr const char *kDefaultRuntimeProfile = "voxel_destruction_only";

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

Vector3 chunk_center_from_dict(const Dictionary &chunk, double chunk_size) {
    const double cx = static_cast<double>(chunk.get("x", 0.0));
    const double cy = static_cast<double>(chunk.get("y", 0.0));
    const double cz = static_cast<double>(chunk.get("z", 0.0));
    return Vector3(
        static_cast<float>((cx + 0.5) * chunk_size),
        static_cast<float>((cy + 0.5) * chunk_size),
        static_cast<float>((cz + 0.5) * chunk_size)
    );
}

bool chunk_center_from_string(const String &chunk_key, double chunk_size, Vector3 &out_center) {
    const String key = chunk_key.strip_edges();
    if (key.is_empty()) {
        return false;
    }
    const PackedStringArray parts = key.split(":", false);
    if (parts.size() < 2) {
        return false;
    }
    const double cx = static_cast<double>(parts[0].to_int());
    const double cz = static_cast<double>(parts[1].to_int());
    out_center = Vector3(
        static_cast<float>((cx + 0.5) * chunk_size),
        static_cast<float>(chunk_size * 0.5),
        static_cast<float>((cz + 0.5) * chunk_size)
    );
    return true;
}

bool region_center(const Variant &region_variant, Vector3 &out_center) {
    const Dictionary region = as_dictionary(region_variant);
    if (region.is_empty() || !static_cast<bool>(region.get("valid", false))) {
        return false;
    }
    const Dictionary min_point = as_dictionary(region.get("min", Dictionary()));
    const Dictionary max_point = as_dictionary(region.get("max", Dictionary()));
    if (min_point.is_empty() || max_point.is_empty()) {
        return false;
    }
    const Vector3 min_vec(
        static_cast<float>(static_cast<double>(min_point.get("x", 0.0))),
        static_cast<float>(static_cast<double>(min_point.get("y", 0.0))),
        static_cast<float>(static_cast<double>(min_point.get("z", 0.0)))
    );
    const Vector3 max_vec(
        static_cast<float>(static_cast<double>(max_point.get("x", 0.0))),
        static_cast<float>(static_cast<double>(max_point.get("y", 0.0))),
        static_cast<float>(static_cast<double>(max_point.get("z", 0.0)))
    );
    out_center = (min_vec + max_vec) * 0.5;
    return true;
}

String normalize_arg(const String &arg) {
    return arg.strip_edges().to_lower();
}

bool parse_bool_token(const String &value, bool &out_value) {
    const String normalized = normalize_arg(value);
    if (normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "on") {
        out_value = true;
        return true;
    }
    if (normalized == "0" || normalized == "false" || normalized == "no" || normalized == "off") {
        out_value = false;
        return true;
    }
    return false;
}

Dictionary make_voxel_destruction_only_profile() {
    Dictionary controller;
    controller["simulation_ticks_per_second"] = 4.0;
    controller["living_profile_push_interval_ticks"] = 4;
    controller["visual_environment_update_interval_ticks"] = 2;
    controller["hud_refresh_interval_ticks"] = 1;
    controller["day_night_cycle_enabled"] = false;

    Dictionary graphics;
    graphics["transform_stage_a_system_enabled"] = false;
    graphics["transform_stage_b_system_enabled"] = false;
    graphics["transform_stage_c_system_enabled"] = true;
    graphics["transform_stage_d_system_enabled"] = false;
    graphics["resource_pipeline_enabled"] = false;
    graphics["structure_lifecycle_enabled"] = false;
    graphics["culture_cycle_enabled"] = false;
    graphics["ecology_system_enabled"] = false;
    graphics["settlement_system_enabled"] = false;
    graphics["villager_system_enabled"] = false;
    graphics["cognition_system_enabled"] = false;
    graphics["smell_gpu_compute_enabled"] = false;
    graphics["wind_gpu_compute_enabled"] = false;
    graphics["voxel_gate_smell_enabled"] = false;
    graphics["voxel_gate_plants_enabled"] = false;
    graphics["voxel_gate_mammals_enabled"] = false;
    graphics["voxel_gate_shelter_enabled"] = false;
    graphics["voxel_gate_profile_refresh_enabled"] = false;
    graphics["voxel_gate_edible_index_enabled"] = false;
    graphics["voxel_process_gating_enabled"] = true;
    graphics["voxel_dynamic_tick_rate_enabled"] = true;
    graphics["voxel_tick_min_interval_seconds"] = 0.12;
    graphics["voxel_tick_max_interval_seconds"] = 0.9;

    Dictionary settings;
    settings["controller"] = controller;
    settings["graphics"] = graphics;
    return settings;
}

Dictionary make_full_sim_profile() {
    Dictionary controller;
    controller["simulation_ticks_per_second"] = 4.0;
    controller["living_profile_push_interval_ticks"] = 4;
    controller["visual_environment_update_interval_ticks"] = 2;
    controller["hud_refresh_interval_ticks"] = 1;
    controller["day_night_cycle_enabled"] = true;

    Dictionary graphics;
    graphics["water_shader_enabled"] = true;
    graphics["ocean_surface_enabled"] = true;
    graphics["river_overlays_enabled"] = true;
    graphics["rain_post_fx_enabled"] = true;
    graphics["clouds_enabled"] = true;
    graphics["cloud_quality"] = "medium";
    graphics["cloud_density_scale"] = 0.6;
    graphics["rain_visual_intensity_scale"] = 0.65;
    graphics["shadows_enabled"] = true;
    graphics["ssao_enabled"] = true;
    graphics["glow_enabled"] = true;
    graphics["simulation_rate_override_enabled"] = false;
    graphics["simulation_locality_enabled"] = false;
    graphics["transform_stage_a_solver_decimation_enabled"] = false;
    graphics["transform_stage_b_solver_decimation_enabled"] = false;
    graphics["transform_stage_c_solver_decimation_enabled"] = false;
    graphics["transform_stage_d_solver_decimation_enabled"] = false;
    graphics["resource_pipeline_decimation_enabled"] = false;
    graphics["structure_lifecycle_decimation_enabled"] = false;
    graphics["culture_cycle_decimation_enabled"] = false;
    graphics["ecology_step_decimation_enabled"] = false;

    Dictionary settings;
    settings["controller"] = controller;
    settings["graphics"] = graphics;
    return settings;
}

Dictionary make_lightweight_demo_profile() {
    Dictionary controller;
    controller["simulation_ticks_per_second"] = 4.0;
    controller["living_profile_push_interval_ticks"] = 8;
    controller["visual_environment_update_interval_ticks"] = 8;
    controller["hud_refresh_interval_ticks"] = 4;
    controller["day_night_cycle_enabled"] = false;

    Dictionary graphics;
    graphics["water_shader_enabled"] = false;
    graphics["ocean_surface_enabled"] = false;
    graphics["river_overlays_enabled"] = false;
    graphics["rain_post_fx_enabled"] = false;
    graphics["clouds_enabled"] = false;
    graphics["shadows_enabled"] = false;
    graphics["ssr_enabled"] = false;
    graphics["ssao_enabled"] = false;
    graphics["ssil_enabled"] = false;
    graphics["sdfgi_enabled"] = false;
    graphics["glow_enabled"] = false;
    graphics["fog_enabled"] = false;
    graphics["volumetric_fog_enabled"] = false;
    graphics["simulation_rate_override_enabled"] = true;
    graphics["simulation_ticks_per_second_override"] = 2.0;
    graphics["simulation_locality_enabled"] = true;
    graphics["simulation_locality_dynamic_enabled"] = true;
    graphics["simulation_locality_radius_tiles"] = 1;
    graphics["transform_stage_a_solver_decimation_enabled"] = true;
    graphics["transform_stage_b_solver_decimation_enabled"] = true;
    graphics["transform_stage_c_solver_decimation_enabled"] = true;
    graphics["transform_stage_d_solver_decimation_enabled"] = true;
    graphics["resource_pipeline_decimation_enabled"] = true;
    graphics["structure_lifecycle_decimation_enabled"] = true;
    graphics["culture_cycle_decimation_enabled"] = true;
    graphics["transform_stage_a_texture_upload_decimation_enabled"] = true;
    graphics["transform_stage_b_texture_upload_decimation_enabled"] = true;
    graphics["transform_stage_d_texture_upload_decimation_enabled"] = true;
    graphics["texture_upload_interval_ticks"] = 12;
    graphics["texture_upload_budget_texels"] = 2048;
    graphics["ecology_step_decimation_enabled"] = true;
    graphics["ecology_step_interval_seconds"] = 0.35;
    graphics["smell_gpu_compute_enabled"] = false;
    graphics["wind_gpu_compute_enabled"] = false;
    graphics["voxel_process_gating_enabled"] = true;
    graphics["voxel_dynamic_tick_rate_enabled"] = true;
    graphics["voxel_tick_min_interval_seconds"] = 0.12;
    graphics["voxel_tick_max_interval_seconds"] = 0.9;

    Dictionary settings;
    settings["controller"] = controller;
    settings["graphics"] = graphics;
    return settings;
}

Dictionary make_default_profile_settings() {
    Dictionary graphics;
    graphics["transform_stage_a_system_enabled"] = false;
    graphics["transform_stage_b_system_enabled"] = false;
    graphics["transform_stage_c_system_enabled"] = false;
    graphics["transform_stage_d_system_enabled"] = false;
    graphics["resource_pipeline_enabled"] = false;
    graphics["structure_lifecycle_enabled"] = false;
    graphics["culture_cycle_enabled"] = false;
    graphics["ecology_system_enabled"] = false;
    graphics["settlement_system_enabled"] = false;
    graphics["villager_system_enabled"] = false;
    graphics["cognition_system_enabled"] = false;
    graphics["simulation_rate_override_enabled"] = true;
    graphics["simulation_ticks_per_second_override"] = 2.0;

    Dictionary settings;
    settings["graphics"] = graphics;
    return settings;
}

} // namespace

void LocalAgentsWorldSimulationNativeUtils::_bind_methods() {
    ClassDB::bind_method(D_METHOD("build_mutation_glow_positions", "payload", "chunk_size"),
                         &LocalAgentsWorldSimulationNativeUtils::build_mutation_glow_positions);
    ClassDB::bind_method(D_METHOD("sanitize_test_mode_id", "mode_id"),
                         &LocalAgentsWorldSimulationNativeUtils::sanitize_test_mode_id);
    ClassDB::bind_method(D_METHOD("resolve_test_mode_from_user_args", "default_mode"),
                         &LocalAgentsWorldSimulationNativeUtils::resolve_test_mode_from_user_args,
                         DEFVAL(String()));
    ClassDB::bind_method(D_METHOD("resolve_bool_flag_from_user_args", "flag_name", "default_value"),
                         &LocalAgentsWorldSimulationNativeUtils::resolve_bool_flag_from_user_args);
    ClassDB::bind_method(D_METHOD("runtime_profile_settings", "profile_id"),
                         &LocalAgentsWorldSimulationNativeUtils::runtime_profile_settings);
    ClassDB::bind_method(D_METHOD("sanitize_runtime_demo_profile", "profile_id"),
                         &LocalAgentsWorldSimulationNativeUtils::sanitize_runtime_demo_profile);
}

Array LocalAgentsWorldSimulationNativeUtils::build_mutation_glow_positions(const Dictionary &payload, double chunk_size) const {
    Array centers;
    const double clamped_chunk_size = chunk_size < 1.0 ? 1.0 : chunk_size;
    const Array chunks = as_array(payload.get("changed_chunks", Array()));
    for (int64_t i = 0; i < chunks.size(); i += 1) {
        const Variant chunk_value = chunks[i];
        if (chunk_value.get_type() == Variant::DICTIONARY) {
            centers.append(chunk_center_from_dict(static_cast<Dictionary>(chunk_value), clamped_chunk_size));
            continue;
        }
        if (chunk_value.get_type() == Variant::STRING) {
            Vector3 center;
            if (chunk_center_from_string(static_cast<String>(chunk_value), clamped_chunk_size, center)) {
                centers.append(center);
            }
        }
    }

    if (centers.is_empty()) {
        Vector3 center;
        if (region_center(payload.get("changed_region", Dictionary()), center)) {
            centers.append(center);
        }
    }
    return centers;
}

String LocalAgentsWorldSimulationNativeUtils::sanitize_test_mode_id(const String &mode_id) const {
    const String normalized = mode_id.strip_edges().to_lower();
    if (normalized == String(kTestModeFpsFireDestroy)) {
        return normalized;
    }
    return String();
}

String LocalAgentsWorldSimulationNativeUtils::resolve_test_mode_from_user_args(const String &default_mode) const {
    OS *os = OS::get_singleton();
    if (os == nullptr) {
        return default_mode;
    }
    const PackedStringArray args = os->get_cmdline_user_args();
    for (int64_t i = 0; i < args.size(); i += 1) {
        const String arg = args[i].strip_edges();
        const String prefix = "--test_mode=";
        if (arg.begins_with(prefix)) {
            return sanitize_test_mode_id(arg.substr(prefix.length()));
        }
        if (arg == "--test_mode" && i + 1 < args.size()) {
            return sanitize_test_mode_id(args[i + 1]);
        }
    }
    return default_mode;
}

bool LocalAgentsWorldSimulationNativeUtils::resolve_bool_flag_from_user_args(const String &flag_name, bool default_value) const {
    OS *os = OS::get_singleton();
    if (os == nullptr) {
        return default_value;
    }
    const String flag = String("--") + flag_name;
    const PackedStringArray args = os->get_cmdline_user_args();
    for (int64_t i = 0; i < args.size(); i += 1) {
        const String arg = normalize_arg(args[i]);
        if (arg == flag) {
            return true;
        }
        const String prefix = flag + String("=");
        if (arg.begins_with(prefix)) {
            bool parsed = false;
            bool value = default_value;
            parsed = parse_bool_token(arg.substr(prefix.length()), value);
            if (parsed) {
                return value;
            }
        }
        if (arg == flag && i + 1 < args.size()) {
            bool parsed = false;
            bool value = default_value;
            parsed = parse_bool_token(args[i + 1], value);
            if (parsed) {
                return value;
            }
        }
    }
    return default_value;
}

String LocalAgentsWorldSimulationNativeUtils::sanitize_runtime_demo_profile(const String &profile_id) const {
    const String normalized = profile_id.strip_edges().to_lower();
    if (normalized == "full_sim" || normalized == "voxel_destruction_only" || normalized == "lightweight_demo") {
        return normalized;
    }
    return String(kDefaultRuntimeProfile);
}

Dictionary LocalAgentsWorldSimulationNativeUtils::runtime_profile_settings(const String &profile_id) const {
    const String normalized = sanitize_runtime_demo_profile(profile_id);
    if (normalized == "voxel_destruction_only") {
        return make_voxel_destruction_only_profile();
    }
    if (normalized == "full_sim") {
        return make_full_sim_profile();
    }
    if (normalized == "lightweight_demo") {
        return make_lightweight_demo_profile();
    }
    return make_default_profile_settings();
}
