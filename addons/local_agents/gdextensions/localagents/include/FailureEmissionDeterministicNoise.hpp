#ifndef FAILURE_EMISSION_DETERMINISTIC_NOISE_HPP
#define FAILURE_EMISSION_DETERMINISTIC_NOISE_HPP

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>

namespace local_agents::simulation {

struct DeterministicNoiseProfile {
    int64_t seed = 0;
    double amplitude = 0.0;
    double frequency = 0.0;
    int32_t octaves = 0;
    double lacunarity = 2.0;
    double gain = 0.5;
    godot::String mode = godot::String("none");
};

DeterministicNoiseProfile build_failure_deterministic_noise_profile(
    int64_t base_seed,
    const godot::String &dominant_mode,
    const godot::String &failure_reason,
    double fracture_radius,
    double fracture_value,
    bool is_cleave
);

void write_deterministic_noise_fields(godot::Dictionary &payload, const DeterministicNoiseProfile &profile);
void read_deterministic_noise_fields(const godot::Dictionary &payload, DeterministicNoiseProfile &profile);

double sample_deterministic_noise_falloff(
    const DeterministicNoiseProfile &profile,
    int32_t center_x,
    int32_t center_y,
    int32_t center_z,
    int32_t sample_x,
    int32_t sample_y,
    int32_t sample_z,
    double base_falloff
);

} // namespace local_agents::simulation

#endif // FAILURE_EMISSION_DETERMINISTIC_NOISE_HPP
