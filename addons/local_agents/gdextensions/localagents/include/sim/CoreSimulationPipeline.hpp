#ifndef LOCAL_AGENTS_UNIFIED_SIMULATION_PIPELINE_HPP
#define LOCAL_AGENTS_UNIFIED_SIMULATION_PIPELINE_HPP

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>

namespace local_agents::simulation {

class CoreSimulationPipeline final {
public:
    enum class TransformStageId : uint8_t {
        kUnknown = 0,
        kThermalTransform = 1,
        kPressureTransform = 2,
        kDestructionTransform = 3,
        kRadianceTransform = 4
    };
    // Deprecated compatibility alias. Prefer TransformStageId.
    using EnvironmentStageId = TransformStageId;

    struct TransformStageDispatch {
        bool is_routed = false;
        bool is_routable = false;
        godot::String requested_stage_name;
        godot::String dispatched_stage_name;
        TransformStageId stage_id = TransformStageId::kUnknown;
        uint8_t domain_mask = 0;
    };
    // Deprecated compatibility alias. Prefer TransformStageDispatch.
    using EnvironmentStageDispatch = TransformStageDispatch;

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
    TransformStageDispatch resolve_transform_stage_dispatch(const godot::String &requested_stage_name) const;

    godot::Dictionary config_;
    godot::Array required_channels_;
    godot::Array mechanics_stages_;
    godot::Array pressure_stages_;
    godot::Array thermal_stages_;
    godot::Array reaction_stages_;
    godot::Array destruction_stages_;
    int64_t executed_steps_ = 0;
    godot::Dictionary last_step_summary_;
    godot::Dictionary carried_field_inputs_;
};

} // namespace local_agents::simulation

#endif // LOCAL_AGENTS_UNIFIED_SIMULATION_PIPELINE_HPP
