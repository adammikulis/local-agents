#include "SimulationFailureEmissionPlanner.hpp"
#include "FailureEmissionDeterministicNoise.hpp"

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>

using namespace godot;

namespace local_agents::simulation {
namespace {
constexpr double kContactWatchSpeedThreshold = 0.0;
constexpr double kContactWatchSpeedWeight = 0.0;
constexpr double kSignalOffset = 1.0;
constexpr double kProjectileSignalGainScale = 1.5e4;
constexpr double kProjectileActiveThresholdScale = 0.0;
constexpr double kProjectileWatchThresholdScale = 0.0;
constexpr double kProjectileDensityScaleDense = 1.0;
constexpr double kProjectileDensityScaleCompact = 1.0;
constexpr double kProjectileDensityScaleSolid = 1.0;
constexpr double kProjectileHardnessScaleHard = 1.0;
constexpr double kProjectileHardnessScaleUltra = 1.0;
constexpr double kProjectileProfileScaleSoft = 1.0;
constexpr double kProjectileProfileScaleDenseHard = 1.0;
constexpr double kProjectileProfileScaleMin = 1.0;
constexpr double kProjectileProfileScaleMax = 3.2;
constexpr double kDefaultMassFallback = 1.0;
constexpr double kImpactMetricScale = 1.0e4;
constexpr double kFallbackFractureRadius = 1.0;
constexpr double kDefaultFractureValueMin = 0.0;
constexpr double kDirectionalityWeightEpsilon = 1.0e-3;
constexpr double kRowSelectionWeightEpsilon = 1.0e-12;
constexpr double kCleaveDirectionalityThreshold = 0.35;

struct ImpactFractureProfile {
    double impact_signal_gain = 1.0e-5;
    double watch_signal_threshold = 2.2;
    double active_signal_threshold = 4.0;
    double fracture_radius_base = 1.0;
    double fracture_radius_gain = 0.5;
    double fracture_radius_max = 12.0;
    double fracture_value_softness = 2.4;
    double fracture_value_cap = 0.95;
};

enum class FailureSeverityLevel : int8_t {
    kStable = 0,
    kWatch = 1,
    kActive = 2
};

struct ContactFailureProjection {
    FailureSeverityLevel severity = FailureSeverityLevel::kStable;
    String reason = String("no_contact");
    String mode = String("stable");
    double impact_signal = 0.0;
    double strongest_impulse = 0.0;
    double strongest_relative_speed = 0.0;
    double aggregated_impulse = 0.0;
    double aggregated_relative_speed = 0.0;
    double impact_work = 0.0;
    double estimated_mass = kDefaultMassFallback;
    double sample_count = 0.0;
    Vector3 normal = Vector3(0.0, 0.0, 0.0);
    double directionality_quality = 0.0;
    int32_t center_x = 0;
    int32_t center_y = 0;
    int32_t center_z = 0;
    bool has_center = false;
};

Dictionary build_point_dict(int32_t x, int32_t y, int32_t z) {
    Dictionary point;
    point["x"] = x;
    point["y"] = y;
    point["z"] = z;
    return point;
}

Dictionary build_vector_dict(double x, double y, double z) {
    Dictionary vec;
    vec["x"] = x;
    vec["y"] = y;
    vec["z"] = z;
    return vec;
}

double get_numeric_dictionary_value(const Dictionary &row, const StringName &key) {
    if (!row.has(key)) {
        return 0.0;
    }
    const Variant value = row[key];
    switch (value.get_type()) {
        case Variant::INT:
            return static_cast<double>(static_cast<int64_t>(value));
        case Variant::FLOAT:
            return static_cast<double>(value);
        default:
            return 0.0;
    }
}

FailureSeverityLevel failure_severity_from_text(const String &status) {
    if (status == String("active")) {
        return FailureSeverityLevel::kActive;
    }
    if (status == String("watch")) {
        return FailureSeverityLevel::kWatch;
    }
    return FailureSeverityLevel::kStable;
}

double contact_impulse_from_row(const Dictionary &row) {
    const double contact_impulse = get_numeric_dictionary_value(row, StringName("contact_impulse"));
    if (contact_impulse != 0.0) {
        return contact_impulse;
    }
    return get_numeric_dictionary_value(row, StringName("impulse"));
}

String get_string_dictionary_value(const Dictionary &row, const StringName &key, const String &fallback) {
    if (!row.has(key)) {
        return fallback;
    }
    const Variant value = row[key];
    if (value.get_type() == Variant::STRING) {
        return String(value);
    }
    if (value.get_type() == Variant::STRING_NAME) {
        return String(static_cast<StringName>(value));
    }
    return fallback;
}

bool is_voxel_chunk_projectile_row(const Dictionary &row) {
    const String projectile_kind = get_string_dictionary_value(row, StringName("projectile_kind"), String());
    return projectile_kind.strip_edges().to_lower() == String("voxel_chunk");
}

double resolve_projectile_signal_scale(const Dictionary &row) {
    if (!is_voxel_chunk_projectile_row(row)) {
        return 1.0;
    }

    double scale = 1.0;
    const String projectile_density_tag = get_string_dictionary_value(row, StringName("projectile_density_tag"), String());
    const String density_key = projectile_density_tag.strip_edges().to_lower();
    if (density_key == String("dense")) {
        scale *= kProjectileDensityScaleDense;
    } else if (density_key == String("solid")) {
        scale *= kProjectileDensityScaleSolid;
    } else if (density_key == String("compact")) {
        scale *= kProjectileDensityScaleCompact;
    }

    const String projectile_hardness_tag = get_string_dictionary_value(row, StringName("projectile_hardness_tag"), String());
    const String hardness_key = projectile_hardness_tag.strip_edges().to_lower();
    if (hardness_key == String("hard")) {
        scale *= kProjectileHardnessScaleHard;
    } else if (hardness_key == String("ultra")) {
        scale *= kProjectileHardnessScaleUltra;
    }

    const String profile_key = get_string_dictionary_value(row, StringName("failure_emission_profile"), String());
    const String profile_key_lc = profile_key.strip_edges().to_lower();
    if (profile_key_lc.find("dense_hard") != -1) {
        scale *= kProjectileProfileScaleDenseHard;
    } else if (profile_key_lc.find("fragile") != -1 || profile_key_lc.find("soft") != -1) {
        scale *= kProjectileProfileScaleSoft;
    }
    return std::clamp(scale, kProjectileProfileScaleMin, kProjectileProfileScaleMax);
}

double read_collision_mass_proxy(const Dictionary &row) {
    const double body_mass = get_numeric_dictionary_value(row, StringName("body_mass"));
    const double collider_mass = get_numeric_dictionary_value(row, StringName("collider_mass"));
    if (body_mass > 0.0 && collider_mass > 0.0) {
        return std::fmax(kDefaultMassFallback, (body_mass * collider_mass) / (body_mass + collider_mass));
    }
    if (body_mass > 0.0) {
        return body_mass;
    }
    if (collider_mass > 0.0) {
        return collider_mass;
    }
    return kDefaultMassFallback;
}

bool read_vector3_from_row(const Dictionary &row, const StringName &key, Vector3 &out) {
    const Variant raw = row.get(key, Vector3());
    if (raw.get_type() == Variant::VECTOR3) {
        out = static_cast<Vector3>(raw);
        return true;
    }
    if (raw.get_type() != Variant::DICTIONARY) {
        return false;
    }
    const Dictionary raw_point = raw;
    const double x = get_numeric_dictionary_value(raw_point, StringName("x"));
    const double y = get_numeric_dictionary_value(raw_point, StringName("y"));
    const double z = get_numeric_dictionary_value(raw_point, StringName("z"));
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) {
        return false;
    }
    out = Vector3(x, y, z);
    return true;
}

bool read_vector3_from_row_keys(
    const Dictionary &row,
    const StringName &preferred_key,
    const StringName &fallback_key,
    Vector3 &out
) {
    if (read_vector3_from_row(row, preferred_key, out)) {
        return true;
    }
    return read_vector3_from_row(row, fallback_key, out);
}

double normalize_mass_proxy(const Dictionary &row, double relative_speed, double impulse) {
    const double direct_mass = read_collision_mass_proxy(row);
    if (direct_mass > 0.0 && std::isfinite(direct_mass)) {
        return direct_mass;
    }
    if (relative_speed <= 0.0) {
        return kDefaultMassFallback;
    }
    const double derived_mass = std::fabs(impulse) / std::max(std::fabs(relative_speed), 1e-6);
    return std::fmax(kDefaultMassFallback, derived_mass);
}

double safe_divide(double numerator, double denominator) {
    if (std::fabs(denominator) <= 1e-12) {
        return 0.0;
    }
    return numerator / denominator;
}

bool read_center_voxel(const Variant &raw_point, int32_t &out_x, int32_t &out_y, int32_t &out_z) {
    if (raw_point.get_type() == Variant::VECTOR3) {
        const Vector3 point = raw_point;
        if (!std::isfinite(point.x) || !std::isfinite(point.y) || !std::isfinite(point.z)) {
            return false;
        }
        out_x = static_cast<int32_t>(std::llround(point.x));
        out_y = static_cast<int32_t>(std::llround(point.y));
        out_z = static_cast<int32_t>(std::llround(point.z));
        return true;
    }
    if (raw_point.get_type() != Variant::DICTIONARY) {
        return false;
    }
    const Dictionary point = raw_point;
    const double raw_x = get_numeric_dictionary_value(point, StringName("x"));
    const double raw_y = get_numeric_dictionary_value(point, StringName("y"));
    const double raw_z = get_numeric_dictionary_value(point, StringName("z"));
    if (!std::isfinite(raw_x) || !std::isfinite(raw_y) || !std::isfinite(raw_z)) {
        return false;
    }
    out_x = static_cast<int32_t>(std::llround(raw_x));
    out_y = static_cast<int32_t>(std::llround(raw_y));
    out_z = static_cast<int32_t>(std::llround(raw_z));
    return true;
}

uint64_t stable_row_tie_breaker_key(
    const Dictionary &row,
    bool has_center,
    int32_t center_x,
    int32_t center_y,
    int32_t center_z,
    bool has_normal,
    const Vector3 &normal,
    double row_impulse,
    double row_relative_speed,
    double row_work
) {
    auto mix = [](uint64_t seed, uint64_t value) {
        constexpr uint64_t kFnvPrime = 1099511628211ULL;
        constexpr uint64_t kKnuth = 0x9e3779b97f4a7c15ULL;
        seed ^= value + kKnuth + (seed << 6) + (seed >> 2);
        return seed * kFnvPrime;
    };

    auto quantized = [](double value, double scale) {
        if (!std::isfinite(value)) {
            return static_cast<int64_t>(0);
        }
        return static_cast<int64_t>(std::llround(value * scale));
    };

    uint64_t key = 1469598103934665603ULL;
    key = mix(key, static_cast<uint64_t>(has_center ? 0 : 1));
    key = mix(key, static_cast<uint64_t>(static_cast<int64_t>(center_x)));
    key = mix(key, static_cast<uint64_t>(static_cast<int64_t>(center_y)));
    key = mix(key, static_cast<uint64_t>(static_cast<int64_t>(center_z)));
    key = mix(key, static_cast<uint64_t>(has_normal ? 0 : 1));
    key = mix(key, static_cast<uint64_t>(quantized(normal.x, 1.0e4)));
    key = mix(key, static_cast<uint64_t>(quantized(normal.y, 1.0e4)));
    key = mix(key, static_cast<uint64_t>(quantized(normal.z, 1.0e4)));
    key = mix(key, static_cast<uint64_t>(quantized(row_impulse, 1.0e6)));
    key = mix(key, static_cast<uint64_t>(quantized(row_relative_speed, 1.0e6)));
    key = mix(key, static_cast<uint64_t>(quantized(row_work, 1.0e6)));
    key = mix(key, static_cast<uint64_t>(quantized(get_numeric_dictionary_value(row, StringName("body_id")), 1.0)));
    key = mix(key, static_cast<uint64_t>(quantized(get_numeric_dictionary_value(row, StringName("collider_id")), 1.0)));
    key = mix(key, static_cast<uint64_t>(quantized(get_numeric_dictionary_value(row, StringName("contact_index")), 1.0)));
    return key;
}

ContactFailureProjection project_contact_failure(
    const Array &contact_rows,
    const ImpactFractureProfile &profile
) {
    ContactFailureProjection projection;
    if (contact_rows.is_empty()) {
        return projection;
    }

    double total_impulse = 0.0;
    double total_relative_speed = 0.0;
    double total_work = 0.0;
    Vector3 weighted_normal = Vector3(0.0, 0.0, 0.0);
    double normal_weight = 0.0;
    int64_t counted_rows = 0;
    bool has_voxel_chunk_projectile_rows = false;
    double best_signal = -1.0;
    uint64_t best_tie_breaker_key = std::numeric_limits<uint64_t>::max();

    for (int64_t i = 0; i < contact_rows.size(); i += 1) {
        const Variant row_variant = contact_rows[i];
        if (row_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary row = row_variant;
        const double row_impulse = std::fabs(contact_impulse_from_row(row));
        const double row_relative_speed = std::fabs(get_numeric_dictionary_value(row, StringName("relative_speed")));
        if (row_impulse <= 0.0 && row_relative_speed <= kContactWatchSpeedThreshold) {
            continue;
        }

        const double row_mass = normalize_mass_proxy(row, row_relative_speed, row_impulse);
        const double row_work = 0.5 * row_mass * row_relative_speed * row_relative_speed;
        const bool row_is_projectile = is_voxel_chunk_projectile_row(row);
        const double projectile_signal_scale = resolve_projectile_signal_scale(row);
        if (row_is_projectile) {
            has_voxel_chunk_projectile_rows = true;
        }
        const double effective_work = row_work * (row_is_projectile ? projectile_signal_scale : 1.0);
        const double row_signal = row_is_projectile
            ? std::log1p(std::fabs(effective_work) * profile.impact_signal_gain * kProjectileSignalGainScale)
            : std::log1p(std::fabs(row_work) * profile.impact_signal_gain + kSignalOffset);
        const double row_weight = row_signal + kContactWatchSpeedWeight * row_relative_speed;

        total_impulse += row_impulse;
        total_relative_speed += row_relative_speed;
        total_work += row_is_projectile ? effective_work : row_work;
        counted_rows += 1;

        int32_t point_x = 0;
        int32_t point_y = 0;
        int32_t point_z = 0;
        const bool has_center = read_center_voxel(row.get("contact_point", Dictionary()), point_x, point_y, point_z);

        Vector3 normal = Vector3(0.0, 0.0, 0.0);
        const bool has_normal = read_vector3_from_row_keys(row, StringName("contact_normal"), StringName("normal"), normal)
            && normal.length_squared() > kRowSelectionWeightEpsilon;
        if (has_normal) {
            normal = normal.normalized();
        }

        const uint64_t row_tie_breaker_key = stable_row_tie_breaker_key(
            row,
            has_center,
            point_x,
            point_y,
            point_z,
            has_normal,
            normal,
            row_impulse,
            row_relative_speed,
            row_work);

        const bool stronger_signal = row_weight > best_signal + kRowSelectionWeightEpsilon;
        const bool equal_signal = std::fabs(row_weight - best_signal) <= kRowSelectionWeightEpsilon;
        if (stronger_signal || (equal_signal && row_tie_breaker_key < best_tie_breaker_key)) {
            projection.center_x = point_x;
            projection.center_y = point_y;
            projection.center_z = point_z;
            projection.has_center = has_center;
            projection.strongest_impulse = row_impulse;
            projection.strongest_relative_speed = row_relative_speed;
            projection.estimated_mass = read_collision_mass_proxy(row);
            best_signal = row_weight;
            best_tie_breaker_key = row_tie_breaker_key;
            if (has_normal) {
                projection.normal = normal;
            }
        }

        if (has_normal) {
            const double weighted_row_contribution = std::max(kDirectionalityWeightEpsilon, row_weight);
            weighted_normal += normal * weighted_row_contribution;
            normal_weight += weighted_row_contribution;
        }
    }

    if (counted_rows <= 0) {
        return projection;
    }

    projection.aggregated_impulse = total_impulse;
    projection.aggregated_relative_speed = safe_divide(total_relative_speed, static_cast<double>(counted_rows));
    projection.impact_work = total_work;
    const double relative_speed_denominator = std::max(
        1e-6,
        std::fabs(projection.aggregated_relative_speed) * std::fabs(projection.aggregated_relative_speed) * static_cast<double>(counted_rows)
    );
    projection.estimated_mass = safe_divide(total_work * 2.0, relative_speed_denominator);
    projection.sample_count = static_cast<double>(counted_rows);
    if (normal_weight > 0.0 && weighted_normal.length_squared() > 0.0) {
        const Vector3 normalized_weighted_normal = (weighted_normal / normal_weight);
        projection.directionality_quality = std::clamp(static_cast<double>(normalized_weighted_normal.length()), 0.0, 1.0);
        projection.normal = normalized_weighted_normal.normalized();
    }
    projection.impact_signal = has_voxel_chunk_projectile_rows
        ? std::log1p(std::fabs(total_work) * profile.impact_signal_gain * kProjectileSignalGainScale)
        : std::log1p(std::fabs(total_work) * profile.impact_signal_gain + kSignalOffset);

    const double active_signal_threshold = has_voxel_chunk_projectile_rows
        ? std::max(0.0, profile.active_signal_threshold * kProjectileActiveThresholdScale)
        : profile.active_signal_threshold;
    const double watch_signal_threshold = has_voxel_chunk_projectile_rows
        ? std::max(0.0, profile.watch_signal_threshold * kProjectileWatchThresholdScale)
        : profile.watch_signal_threshold;

    if (projection.impact_signal >= active_signal_threshold) {
        projection.severity = FailureSeverityLevel::kActive;
        projection.reason = String("impact_critical");
        projection.mode = String("impact");
    } else if (
        projection.impact_signal >= watch_signal_threshold || projection.strongest_relative_speed >= kContactWatchSpeedThreshold
    ) {
        projection.severity = FailureSeverityLevel::kWatch;
        projection.reason = String("watch_impact");
        projection.mode = String("impact_watch");
    }
    return projection;
}

double fracture_value_from_contact_projection(
    const ContactFailureProjection &projection,
    const ImpactFractureProfile &profile
) {
    if (projection.severity != FailureSeverityLevel::kActive) {
        return 0.0;
    }
    const double damage_fraction = 1.0 - std::exp(-projection.impact_signal / std::max(1e-6, profile.fracture_value_softness));
    const double normal_factor = 0.9 + 0.2 * std::fabs(projection.normal.dot(Vector3(0.0, 1.0, 0.0)));
    const double mass_factor = std::clamp(std::log1p(std::fmax(0.0, projection.estimated_mass)) / 8.0, 0.0, 1.0);
    const double samples = std::clamp(std::sqrt(std::fmax(1.0, projection.sample_count)) / 3.0, 0.0, 1.0);
    return std::clamp(
        profile.fracture_value_cap * (0.15 + 0.7 * damage_fraction + 0.1 * mass_factor + 0.15 * samples) * normal_factor,
        kDefaultFractureValueMin,
        profile.fracture_value_cap);
}

double fracture_radius_from_contact_projection(
    const ContactFailureProjection &projection,
    const ImpactFractureProfile &profile
) {
    if (projection.severity != FailureSeverityLevel::kActive) {
        return kFallbackFractureRadius;
    }
    const double normalized_signal = std::fmax(0.0, projection.impact_signal);
    return std::clamp(
        profile.fracture_radius_base + profile.fracture_radius_gain * std::sqrt(normalized_signal) * (1.0 + 0.15 * projection.normal.length()),
        1.0,
        profile.fracture_radius_max);
}

double fracture_radius_from_pipeline_metrics(
    double overstress_ratio,
    double friction_abs,
    double slope_failure_ratio,
    double damage_delta,
    double resistance_avg,
    double fracture_energy,
    const ImpactFractureProfile &profile
) {
    const double normalized_signal = std::fmax(
        0.0,
        std::log1p(
            std::fabs(overstress_ratio)
            + std::fabs(slope_failure_ratio)
            + std::fabs(friction_abs) / kImpactMetricScale
            + std::fabs(damage_delta) / kImpactMetricScale
            + std::fabs(resistance_avg) / 1.0e5
            + std::fabs(fracture_energy) / kImpactMetricScale
        )
    );
    const double damage_term = std::log1p(std::fmax(0.0, damage_delta) / kImpactMetricScale);
    const double resistance_term = std::log1p(std::fmax(0.0, resistance_avg) / kImpactMetricScale);
    const double fracture_term = std::log1p(std::fabs(fracture_energy) / kImpactMetricScale);
    const double impact_signal = normalized_signal + damage_term + resistance_term + fracture_term;
    return std::clamp(
        profile.fracture_radius_base + profile.fracture_radius_gain * std::sqrt(std::fmax(0.0, impact_signal)),
        1.0,
        profile.fracture_radius_max);
}

double fracture_value_from_pipeline_metrics(
    double overstress_ratio,
    double friction_abs,
    double slope_failure_ratio,
    double damage_delta,
    double resistance_avg,
    double fracture_energy,
    const ImpactFractureProfile &profile
) {
    const double normalized = (
        std::fmin(1.0, std::fabs(overstress_ratio))
        + std::fmin(1.0, std::fabs(slope_failure_ratio))
        + std::fmin(1.0, std::fabs(resistance_avg) / 1.0e6)
        + std::fmin(1.0, std::fabs(damage_delta) / 1.0e6)
        + std::fmin(1.0, std::fabs(friction_abs) / 1.0e6)
        + std::fmin(1.0, std::fabs(fracture_energy) / 1.0e6)
    ) / 5.0;
    return std::clamp(
        profile.fracture_value_cap * std::fmin(1.0, 1.0 - std::exp(-normalized / std::max(1e-6, profile.fracture_value_softness))),
        0.0,
        1.0);
}

Dictionary build_fracture_payload(
    int32_t x,
    int32_t y,
    int32_t z,
    double radius,
    double value,
    const Vector3 &impact_normal
) {
    Dictionary op_payload;
    op_payload["x"] = x;
    op_payload["y"] = y;
    op_payload["z"] = z;
    op_payload["center"] = build_point_dict(x, y, z);
    op_payload["operation"] = String("fracture");
    op_payload["op_kind"] = String("fracture");
    op_payload["shape"] = String("sphere");
    op_payload["radius"] = radius;
    op_payload["value"] = value;
    op_payload["impact_normal"] = build_point_dict(
        static_cast<int32_t>(std::llround(impact_normal.x)),
        static_cast<int32_t>(std::llround(impact_normal.y)),
        static_cast<int32_t>(std::llround(impact_normal.z)));
    return op_payload;
}

Dictionary build_cleave_payload(
    int32_t x,
    int32_t y,
    int32_t z,
    double radius,
    double value,
    const Vector3 &plane_normal
) {
    const Vector3 normalized_normal = plane_normal.length_squared() > kRowSelectionWeightEpsilon
        ? plane_normal.normalized()
        : Vector3(0.0, 1.0, 0.0);
    const double plane_offset = normalized_normal.dot(Vector3(static_cast<double>(x), static_cast<double>(y), static_cast<double>(z)));

    Dictionary op_payload;
    op_payload["x"] = x;
    op_payload["y"] = y;
    op_payload["z"] = z;
    op_payload["center"] = build_point_dict(x, y, z);
    op_payload["operation"] = String("cleave");
    op_payload["op_kind"] = String("cleave");
    op_payload["radius"] = radius;
    op_payload["value"] = value;
    op_payload["plane_normal"] = build_vector_dict(normalized_normal.x, normalized_normal.y, normalized_normal.z);
    op_payload["plane_offset"] = plane_offset;
    return op_payload;
}

String as_status_text(const Variant &value, const String &fallback) {
    if (value.get_type() == Variant::STRING) {
        return String(value);
    }
    if (value.get_type() == Variant::STRING_NAME) {
        return String(static_cast<StringName>(value));
    }
    return fallback;
}

double as_status_float(const Variant &value, double fallback) {
    if (value.get_type() == Variant::FLOAT) {
        return static_cast<double>(value);
    }
    if (value.get_type() == Variant::INT) {
        return static_cast<double>(static_cast<int64_t>(value));
    }
    return fallback;
}

int64_t as_status_int(const Variant &value, int64_t fallback) {
    auto parse_float_to_int64_bounded = [](double raw, int64_t &result) {
        if (!std::isfinite(raw)) {
            return false;
        }
        const double truncated = std::trunc(raw);
        const double min_bound = static_cast<double>(std::numeric_limits<int64_t>::min());
        const double max_bound = static_cast<double>(std::numeric_limits<int64_t>::max());
        if (truncated < min_bound || truncated > max_bound) {
            return false;
        }
        result = static_cast<int64_t>(truncated);
        return true;
    };
    if (value.get_type() == Variant::INT) {
        return static_cast<int64_t>(value);
    }
    if (value.get_type() == Variant::FLOAT) {
        int64_t parsed = fallback;
        if (parse_float_to_int64_bounded(static_cast<double>(value), parsed)) {
            return parsed;
        }
        return fallback;
    }
    return fallback;
}

int32_t clamp_to_bucket(double value, int32_t bucket_count) {
    if (!std::isfinite(value) || bucket_count <= 0) {
        return 0;
    }
    const double bounded_value = std::fabs(value);
    const double wrapped = std::fmod(bounded_value, static_cast<double>(bucket_count));
    const int64_t bucket = static_cast<int64_t>(std::floor(wrapped + 1.0e-12));
    return static_cast<int32_t>(std::max<int64_t>(0, std::min<int64_t>(bucket_count - 1, bucket)));
}

uint64_t mix_u64(uint64_t x) {
    x ^= (x >> 33u);
    x *= 0xff51afd7ed558ccdULL;
    x ^= (x >> 33u);
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= (x >> 33u);
    return x;
}

uint64_t mix_seed_component(uint64_t seed, uint64_t component) {
    constexpr uint64_t kKnuth = 0x9e3779b97f4a7c15ULL;
    return mix_u64(seed ^ (component + kKnuth + (seed << 6u) + (seed >> 2u)));
}

uint64_t string_signature_u64(const String &value) {
    uint64_t signature = 1469598103934665603ULL;
    const int64_t value_length = value.length();
    for (int64_t i = 0; i < value_length; i++) {
        signature ^= static_cast<uint64_t>(value.unicode_at(i));
        signature *= 1099511628211ULL;
    }
    return signature;
}
} // namespace

Dictionary build_voxel_failure_emission_plan(
    const Dictionary &pipeline_feedback,
    const Array &contact_rows,
    double impact_signal_gain,
    double watch_signal_threshold,
    double active_signal_threshold,
    double fracture_radius_base,
    double fracture_radius_gain,
    double fracture_radius_max,
    double fracture_value_softness,
    double fracture_value_cap
) {
    const ImpactFractureProfile profile = {
        impact_signal_gain,
        watch_signal_threshold,
        active_signal_threshold,
        fracture_radius_base,
        fracture_radius_gain,
        fracture_radius_max,
        fracture_value_softness,
        fracture_value_cap
    };

    Dictionary plan;
    plan["status"] = String("disabled");
    plan["reason"] = String("no_active_failure");
    plan["target_domain"] = String("environment");
    plan["stage_name"] = String("physics_failure_emission");
    plan["dominant_mode"] = String("stable");
    plan["dominant_stage_index"] = static_cast<int64_t>(-1);
    plan["planned_op_count"] = static_cast<int64_t>(0);
    plan["executed_op_count"] = static_cast<int64_t>(0);
    plan["op_kind"] = String("none");
    plan["op_payloads"] = Array();
    plan["execution"] = Dictionary();
    plan["pipeline_feedback_reference"] = pipeline_feedback.duplicate(true);
    const ContactFailureProjection contact_projection = project_contact_failure(contact_rows, profile);

    if (pipeline_feedback.is_empty() && contact_projection.severity == FailureSeverityLevel::kStable) {
        return plan;
    }

    const Dictionary failure_feedback = pipeline_feedback.get("failure_feedback", Dictionary());
    const String failure_status = as_status_text(failure_feedback.get("status", String("idle")), String("idle"));
    const FailureSeverityLevel pipeline_severity = failure_severity_from_text(failure_status);
    const FailureSeverityLevel combined_severity = std::max(pipeline_severity, contact_projection.severity);
    if (combined_severity == FailureSeverityLevel::kStable) {
        plan["reason"] = failure_status == String("watch") ? String("watch_mode_only") : String("no_active_failure");
        return plan;
    }

    if (combined_severity == FailureSeverityLevel::kWatch) {
        if (contact_projection.severity == FailureSeverityLevel::kWatch) {
            plan["reason"] = contact_projection.reason;
            plan["dominant_mode"] = contact_projection.mode;
        } else {
            plan["reason"] = String("watch_mode_only");
        }
        return plan;
    }

    const bool use_pipeline_failure = pipeline_severity == FailureSeverityLevel::kActive;
    const Dictionary destruction = pipeline_feedback.get("destruction", Dictionary());
    const Dictionary failure_source = pipeline_feedback.get("failure_source", Dictionary());
    const Dictionary voxel_summary = pipeline_feedback.get("voxel_emission", Dictionary());
    const String failure_reason = use_pipeline_failure ? as_status_text(failure_feedback.get("reason", String("active_failure")), String("active_failure")) : contact_projection.reason;
    const String dominant_mode = use_pipeline_failure ? as_status_text(failure_feedback.get("dominant_mode", String("stable")), String("stable")) : contact_projection.mode;
    const int64_t dominant_stage_index = as_status_int(failure_feedback.get("dominant_stage_index", -1), -1);

    const double overstress_ratio = std::fmax(0.0, as_status_float(failure_source.get("overstress_ratio_max", 0.0), 0.0));
    const double friction_abs = as_status_float(destruction.get("friction_abs_force_max", 0.0), 0.0);
    const double slope_failure_ratio = as_status_float(destruction.get("slope_failure_ratio_max", 0.0), 0.0);
    const double damage_delta = std::fmax(0.0, as_status_float(destruction.get("damage_delta_total", 0.0), 0.0));
    const double resistance_avg = std::fmax(0.0, as_status_float(destruction.get("resistance_avg", 0.0), 0.0));
    const double fracture_energy = std::fmax(0.0, as_status_float(destruction.get("fracture_energy_total", 0.0), 0.0));

    uint64_t seed_hash = 1469598103934665603ULL;
    seed_hash = mix_seed_component(seed_hash, static_cast<uint64_t>(static_cast<int64_t>(dominant_stage_index)));
    seed_hash = mix_seed_component(seed_hash, string_signature_u64(dominant_mode));
    seed_hash = mix_seed_component(seed_hash, string_signature_u64(failure_reason));
    const int64_t seed = static_cast<int64_t>(seed_hash & 0x7FFFFFFFFFFFFFFFULL);
    const int32_t x = clamp_to_bucket(static_cast<double>(seed_hash & 63ULL), 64);
    const int32_t y = clamp_to_bucket(overstress_ratio * 64.0, 64);
    const int32_t z = clamp_to_bucket(friction_abs + slope_failure_ratio + damage_delta + resistance_avg + fracture_energy, 64);
    const double contact_signal_boost = contact_projection.impact_signal / std::max(1.0, profile.active_signal_threshold);
    const double fracture_radius = use_pipeline_failure
        ? std::max(
            fracture_radius_from_pipeline_metrics(overstress_ratio, friction_abs, slope_failure_ratio, damage_delta, resistance_avg, fracture_energy, profile),
            fracture_radius_from_contact_projection(contact_projection, profile) * (1.0 + 0.2 * contact_signal_boost)
        )
        : fracture_radius_from_contact_projection(contact_projection, profile);
    const double fracture_value = use_pipeline_failure
        ? std::max(
            fracture_value_from_pipeline_metrics(overstress_ratio, friction_abs, slope_failure_ratio, damage_delta, resistance_avg, fracture_energy, profile),
            fracture_value_from_contact_projection(contact_projection, profile) * (0.5 + 0.5 * contact_signal_boost)
        )
        : fracture_value_from_contact_projection(contact_projection, profile);
    const int32_t op_x = contact_projection.has_center && contact_projection.severity == FailureSeverityLevel::kActive ? contact_projection.center_x : x;
    const int32_t op_y = contact_projection.has_center && contact_projection.severity == FailureSeverityLevel::kActive ? contact_projection.center_y : y;
    const int32_t op_z = contact_projection.has_center && contact_projection.severity == FailureSeverityLevel::kActive ? contact_projection.center_z : z;
    const Vector3 impact_normal = contact_projection.normal;
    const bool can_cleave = contact_projection.severity == FailureSeverityLevel::kActive
        && impact_normal.length_squared() > kRowSelectionWeightEpsilon
        && contact_projection.directionality_quality >= kCleaveDirectionalityThreshold;
    const DeterministicNoiseProfile noise_profile = build_failure_deterministic_noise_profile(
        seed,
        dominant_mode,
        failure_reason,
        fracture_radius,
        fracture_value,
        can_cleave);

    Dictionary op_payload = can_cleave
        ? build_cleave_payload(op_x, op_y, op_z, fracture_radius, fracture_value, impact_normal)
        : build_fracture_payload(op_x, op_y, op_z, fracture_radius, fracture_value, impact_normal);
    write_deterministic_noise_fields(op_payload, noise_profile);
    op_payload["reason"] = use_pipeline_failure ? failure_reason : contact_projection.reason;
    op_payload["contact_signal"] = contact_projection.impact_signal;
    op_payload["impact_signal"] = contact_projection.impact_signal;
    op_payload["impact_work"] = contact_projection.impact_work;
    op_payload["directionality_quality"] = contact_projection.directionality_quality;

    Array op_payloads;
    op_payloads.append(op_payload);

    plan["status"] = String("planned");
    plan["reason"] = failure_reason;
    plan["dominant_mode"] = dominant_mode;
    plan["dominant_stage_index"] = dominant_stage_index;
    plan["planned_op_count"] = static_cast<int64_t>(op_payloads.size());
    plan["op_payloads"] = op_payloads;
    plan["target_domain"] = String("environment");
    plan["stage_name"] = String("physics_failure_emission");
    plan["op_kind"] = can_cleave ? String("cleave") : String("fracture");
    plan["directionality_quality"] = contact_projection.directionality_quality;
    if (can_cleave) {
        plan["cleave_plane_normal"] = op_payload.get("plane_normal", Dictionary());
        plan["cleave_plane_offset"] = op_payload.get("plane_offset", 0.0);
    }
    if (voxel_summary.is_empty()) {
        plan["pipeline_voxel_summary_status"] = String("absent");
    }
    return plan;
}

} // namespace local_agents::simulation
