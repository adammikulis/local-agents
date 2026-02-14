#include "FailureEmissionDeterministicNoise.hpp"

#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>
#include <limits>

using namespace godot;

namespace local_agents::simulation {
namespace {
constexpr double kTwoPi = 6.28318530717958647692;
constexpr double kNoiseEpsilon = 1.0e-9;

uint64_t mix64(uint64_t x) {
    x ^= (x >> 33u);
    x *= 0xff51afd7ed558ccdULL;
    x ^= (x >> 33u);
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= (x >> 33u);
    return x;
}

uint64_t string_signature_u64(const String &value) {
    uint64_t signature = 1469598103934665603ULL;
    const int64_t value_length = value.length();
    for (int64_t i = 0; i < value_length; ++i) {
        signature ^= static_cast<uint64_t>(value.unicode_at(i));
        signature *= 1099511628211ULL;
    }
    return signature;
}

bool parse_int64_variant(const Variant &value, int64_t &out) {
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
        out = static_cast<int64_t>(value);
        return true;
    }
    if (value.get_type() == Variant::FLOAT) {
        return parse_float_to_int64_bounded(static_cast<double>(value), out);
    }
    return false;
}

bool parse_int32_variant(const Variant &value, int32_t &out) {
    int64_t parsed = 0;
    if (!parse_int64_variant(value, parsed)) {
        return false;
    }
    if (parsed < static_cast<int64_t>(std::numeric_limits<int32_t>::min()) ||
        parsed > static_cast<int64_t>(std::numeric_limits<int32_t>::max())) {
        return false;
    }
    out = static_cast<int32_t>(parsed);
    return true;
}

bool parse_double_variant(const Variant &value, double &out) {
    if (value.get_type() == Variant::INT) {
        out = static_cast<double>(static_cast<int64_t>(value));
        return true;
    }
    if (value.get_type() == Variant::FLOAT) {
        const double raw = static_cast<double>(value);
        if (!std::isfinite(raw)) {
            return false;
        }
        out = raw;
        return true;
    }
    return false;
}

double deterministic_wave(uint64_t seed, double x, double y, double z, double frequency) {
    const uint64_t phase_hash = mix64(seed ^ 0x9e3779b97f4a7c15ULL);
    const double phase = static_cast<double>(phase_hash & 0xFFFFu) / 65535.0 * kTwoPi;
    const double angle = ((x * 0.754877666) + (y * 0.569840296) + (z * 0.438289123)) * frequency + phase;
    return std::sin(angle);
}
} // namespace

DeterministicNoiseProfile build_failure_deterministic_noise_profile(
    int64_t base_seed,
    const String &dominant_mode,
    const String &failure_reason,
    double fracture_radius,
    double fracture_value,
    bool is_cleave
) {
    const uint64_t signature = mix64(
        static_cast<uint64_t>(base_seed)
        ^ string_signature_u64(dominant_mode)
        ^ (string_signature_u64(failure_reason) << 1u)
        ^ (is_cleave ? 0xA5A5A5A5A5A5A5A5ULL : 0x5A5A5A5A5A5A5A5AULL));

    DeterministicNoiseProfile profile;
    profile.seed = static_cast<int64_t>(signature & 0x7FFFFFFFFFFFFFFFULL);
    profile.amplitude = std::clamp(0.12 + 0.38 * std::fmax(0.0, fracture_value), 0.08, 0.70);
    profile.frequency = std::clamp(0.08 + 0.025 * std::fmax(0.0, fracture_radius), 0.06, 0.85);
    profile.octaves = is_cleave ? 3 : 4;
    profile.lacunarity = 2.0;
    profile.gain = 0.5;
    profile.mode = String("multiply");
    return profile;
}

void write_deterministic_noise_fields(Dictionary &payload, const DeterministicNoiseProfile &profile) {
    payload["noise_seed"] = profile.seed;
    payload["noise_amplitude"] = profile.amplitude;
    payload["noise_frequency"] = profile.frequency;
    payload["noise_octaves"] = profile.octaves;
    payload["noise_lacunarity"] = profile.lacunarity;
    payload["noise_gain"] = profile.gain;
    payload["noise_mode"] = profile.mode;
}

void read_deterministic_noise_fields(const Dictionary &payload, DeterministicNoiseProfile &profile) {
    if (payload.has("noise_seed")) {
        int64_t parsed_seed = 0;
        if (parse_int64_variant(payload["noise_seed"], parsed_seed)) {
            profile.seed = parsed_seed;
        }
    }
    if (payload.has("noise_amplitude")) {
        double parsed = 0.0;
        if (parse_double_variant(payload["noise_amplitude"], parsed)) {
            profile.amplitude = std::clamp(parsed, 0.0, 1.0);
        }
    }
    if (payload.has("noise_frequency")) {
        double parsed = 0.0;
        if (parse_double_variant(payload["noise_frequency"], parsed)) {
            profile.frequency = std::fmax(0.0, parsed);
        }
    }
    if (payload.has("noise_octaves")) {
        int32_t parsed = 0;
        if (parse_int32_variant(payload["noise_octaves"], parsed)) {
            profile.octaves = std::clamp(parsed, 0, 8);
        }
    }
    if (payload.has("noise_lacunarity")) {
        double parsed = 0.0;
        if (parse_double_variant(payload["noise_lacunarity"], parsed)) {
            profile.lacunarity = std::clamp(parsed, 1.0, 8.0);
        }
    }
    if (payload.has("noise_gain")) {
        double parsed = 0.0;
        if (parse_double_variant(payload["noise_gain"], parsed)) {
            profile.gain = std::clamp(parsed, 0.0, 1.0);
        }
    }
    const Variant raw_mode = payload.get("noise_mode", String("none"));
    if (raw_mode.get_type() == Variant::STRING) {
        profile.mode = String(raw_mode).to_lower();
    } else if (raw_mode.get_type() == Variant::STRING_NAME) {
        profile.mode = String(static_cast<StringName>(raw_mode)).to_lower();
    }
    if (profile.mode.is_empty()) {
        profile.mode = String("none");
    }
}

double sample_deterministic_noise_falloff(
    const DeterministicNoiseProfile &profile,
    int32_t center_x,
    int32_t center_y,
    int32_t center_z,
    int32_t sample_x,
    int32_t sample_y,
    int32_t sample_z,
    double base_falloff
) {
    if (base_falloff <= 0.0) {
        return 0.0;
    }
    if (profile.amplitude <= 0.0 || profile.frequency <= kNoiseEpsilon || profile.octaves <= 0) {
        return std::clamp(base_falloff, 0.0, 1.0);
    }

    const double local_x = static_cast<double>(sample_x - center_x);
    const double local_y = static_cast<double>(sample_y - center_y);
    const double local_z = static_cast<double>(sample_z - center_z);

    double frequency = profile.frequency;
    double gain = 1.0;
    double accumulator = 0.0;
    double gain_sum = 0.0;
    for (int32_t octave = 0; octave < profile.octaves; ++octave) {
        const uint64_t octave_seed = mix64(static_cast<uint64_t>(profile.seed) ^ static_cast<uint64_t>(octave + 1));
        accumulator += deterministic_wave(octave_seed, local_x, local_y, local_z, frequency) * gain;
        gain_sum += gain;
        frequency *= profile.lacunarity;
        gain *= profile.gain;
    }
    if (gain_sum <= kNoiseEpsilon) {
        return std::clamp(base_falloff, 0.0, 1.0);
    }

    const double normalized = std::clamp(accumulator / gain_sum, -1.0, 1.0);
    const double centered = 1.0 + profile.amplitude * normalized;
    const double positive_noise = std::clamp(0.5 + 0.5 * normalized, 0.0, 1.0);

    const String mode = profile.mode.to_lower();
    if (mode == String("replace")) {
        return std::clamp(positive_noise, 0.0, 1.0);
    }
    if (mode == String("add")) {
        return std::clamp(base_falloff + (positive_noise - 0.5) * profile.amplitude, 0.0, 1.0);
    }
    return std::clamp(base_falloff * std::clamp(centered, 0.0, 2.0), 0.0, 1.0);
}

} // namespace local_agents::simulation
