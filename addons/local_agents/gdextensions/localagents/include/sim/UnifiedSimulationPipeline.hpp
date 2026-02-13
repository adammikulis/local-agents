#ifndef LOCAL_AGENTS_UNIFIED_SIMULATION_PIPELINE_HPP
#define LOCAL_AGENTS_UNIFIED_SIMULATION_PIPELINE_HPP

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>

namespace local_agents::simulation {

class UnifiedSimulationPipeline final {
public:
    bool configure(const godot::Dictionary &config);
    godot::Dictionary execute_step(const godot::Dictionary &scheduled_frame);
    void reset();
    godot::Dictionary get_debug_snapshot() const;

private:
    godot::Dictionary run_mechanics_stage(
        const godot::Dictionary &stage_config,
        const godot::Dictionary &stage_field_inputs,
        double delta_seconds) const;
    godot::Dictionary run_pressure_stage(
        const godot::Dictionary &stage_config,
        const godot::Dictionary &stage_field_inputs,
        double delta_seconds) const;
    godot::Dictionary run_thermal_stage(
        const godot::Dictionary &stage_config,
        const godot::Dictionary &stage_field_inputs,
        double delta_seconds) const;
    godot::Dictionary run_reaction_stage(
        const godot::Dictionary &stage_config,
        const godot::Dictionary &stage_field_inputs,
        double delta_seconds) const;
    godot::Dictionary run_destruction_stage(
        const godot::Dictionary &stage_config,
        const godot::Dictionary &stage_field_inputs,
        double delta_seconds) const;

    godot::Dictionary config_;
    godot::Array required_channels_;
    godot::Array mechanics_stages_;
    godot::Array pressure_stages_;
    godot::Array thermal_stages_;
    godot::Array reaction_stages_;
    godot::Array destruction_stages_;
    int64_t executed_steps_ = 0;
    godot::Dictionary last_step_summary_;
};

} // namespace local_agents::simulation

#endif // LOCAL_AGENTS_UNIFIED_SIMULATION_PIPELINE_HPP
